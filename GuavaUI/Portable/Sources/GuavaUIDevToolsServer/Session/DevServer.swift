import Foundation
import Dispatch
import GuavaUIDevToolsProtocol
import GuavaLogging

/// WebSocket server with platform-independent protocol dispatch.
/// The transport owns sockets; the host owns UI-thread scheduling.
///
/// The server is opt-in. Application constructs and starts it when an
/// ApplicationConfiguration carries a non-nil DevToolsConfig.
public final class DevServer: @unchecked Sendable {

    typealias Subscription = DevToolsSubscription
    struct Client {
        let connection: any DevToolsConnection
        let session = DevToolsSession()
        var subscriptions: Set<Subscription> { session.subscriptions }
        var lastState: StateObservationPayload?
    }

    let config: DevToolsConfig
    let queue = DispatchQueue(label: "guava.devtools.server")
    let treeEncoder = TreeEncodingWorker()
    let queueKey = DispatchSpecificKey<Void>()
    let transport: any DevToolsTransport
    var isStarted = false
    var generation: UInt64 = 0
    // Access only from queue. Keep one encoding in flight and one pending
    // notification; capture the latest live tree when the pending work runs.
    var treeBroadcastInFlight = false
    var treeBroadcastPending = false

    /// Actual bound port, including when configured with port zero.
    public var boundPort: UInt16? { transport.boundPort }
    /// Access only from `queue`. Keeping the connection and its subscriptions
    /// together prevents stale subscription state after disconnects.
    var clients: [ObjectIdentifier: Client] = [:]
    var recordingOwner: ObjectIdentifier?
    var selectionOwner: ObjectIdentifier?
    var inspectionOwner: ObjectIdentifier?
    var inspectionLease: UUID?
    @MainActor var activeInspectionLease: UUID?

    /// Capabilities announced in `hello`. DevTools configures this before
    /// start so clients do not expose controls with no host-side provider.
    public var host = DevToolsHost()

    public var advertisedCapabilities: [String] = ["tree", "select", "log", "timing"]

    let logs = DevToolsLogFeed()
    var logger: Logger { LogSystem.logger("com.guava.devtools") }

    public init(config: DevToolsConfig, transport: (any DevToolsTransport)? = nil) {
        self.config = config
        self.transport = transport ?? NIODevToolsTransport(accessToken: config.launch?.token)
        queue.setSpecific(key: queueKey, value: ())
    }

    public func start() throws {
        logs.start(self)
        do {
        try onQueueSync {
            guard !isStarted else { return }
            let epoch = generation
            try transport.start(host: config.host, port: config.port) { [weak self] event in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, self.isStarted, self.generation == epoch else { return }
                    switch event {
                    case .connected(let connection):
                        self.clients[ObjectIdentifier(connection)] = Client(connection: connection)
                        self.sendHello(to: connection)
                    case .text(let connection, let data):
                        guard self.clients[ObjectIdentifier(connection)] != nil else { return }
                        self.decodeAndDispatch(data: data, on: connection)
                    case .disconnected(let connection):
                        self.removeClient(connection)
                    }
                }
            }
            isStarted = true
        }
        } catch { logs.stop(); throw error }
        log("DevServer listening on ws://\(config.host):\(boundPort ?? config.port)")
    }

    public func stop() {
        logs.stop()
        let cleanup = onQueueSync { () -> (Bool, Bool, Bool, UUID?) in
            generation &+= 1
            isStarted = false
            treeBroadcastInFlight = false
            treeBroadcastPending = false
            let selection = selectionOwner != nil
            let mirror = clients.values.contains { $0.subscriptions.contains(.mirror) }
            let recording = recordingOwner != nil
            let inspection = inspectionLease
            clients.removeAll()
            selectionOwner = nil
            recordingOwner = nil
            inspectionOwner = nil; inspectionLease = nil
            return (selection, mirror, recording, inspection)
        }
        transport.stop()
        if host.observation.capture != nil { runOnHostMain { [weak self] in self?.syncTimelineCapture() } }
        if cleanup.0 || cleanup.1 || cleanup.2 || cleanup.3 != nil {
            runOnHostMain { [weak self] in
                if cleanup.0, let self, self.onQueueSync({ self.selectionOwner == nil }) { self.host.scene.clearSelection?() }
                if cleanup.1 { self?.host.mirror.stop?() }
                if cleanup.2 { _ = self?.host.recording.stop?() }
                if let lease = cleanup.3 { self?.resetInspection(lease: lease) }
            }
        }
    }

    deinit { transport.stop() }

    /// Capture on the scene thread, then encode once on a dedicated worker.
    /// Bursts coalesce into a trailing snapshot, including in idle hosts.
    @MainActor
    public func broadcastTreeDelta() {
        // A snapshot walks the complete live tree, so do not pay that cost
        // merely because DevTools is enabled.
        let epoch: UInt64? = onQueueSync {
            guard clients.values.contains(where: { $0.subscriptions.contains(.tree) }) else { return nil }
            guard !treeBroadcastInFlight else { treeBroadcastPending = true; return nil }
            treeBroadcastInFlight = true
            return generation
        }
        guard let epoch else { return }
        guard let snapshot = host.scene.snapshot?() else {
            onQueueSync { treeBroadcastInFlight = false }
            return
        }
        encodeTree(snapshot, type: "tree.delta") { [weak self] data in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, self.generation == epoch else { return }
                if let data {
                    for client in self.clients.values where client.subscriptions.contains(.tree) {
                        client.connection.send(text: data)
                    }
                }
                // Bound full-tree traffic to 10 Hz without losing the final
                // change when the editor stops rendering after an input.
                self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, self.generation == epoch else { return }
                    self.treeBroadcastInFlight = false
                    let pending = self.treeBroadcastPending
                    self.treeBroadcastPending = false
                    if pending { self.runOnHostMain { [weak self] in self?.broadcastTreeDelta() } }
                }
            }
        }
    }

    public func broadcastLog(_ entry: LogRecord) { logs.enqueue(entry, server: self) }

    public func broadcastTiming(_ frame: TimingFramePayload) {
        guard hasSubscribers(for: .timing) else { return }
        let env = DevToolsEnvelope(type: "timing.frame", payload: encodeJSON(frame))
        send(env, toSubscribersOf: .timing)
    }

    /// Read only requested summaries on the scene thread. Streams remain opt-in
    /// and unchanged state snapshots are suppressed independently per client.
    @MainActor public func broadcastObservations() {
        let watchers = onQueueSync {
            clients.values.filter { $0.subscriptions.contains(.state) }.map { ($0.connection, $0.session.watchedStateIDs) }
        }
        for (connection, ids) in watchers {
            guard let snapshot = host.observation.state?(ids) else { continue }
            queue.async { [weak self] in
                guard let self, var client = self.clients[ObjectIdentifier(connection)],
                      client.subscriptions.contains(.state), client.session.watchedStateIDs == ids,
                      client.lastState != snapshot else { return }
                client.lastState = snapshot; self.clients[ObjectIdentifier(connection)] = client
                self.send(DevToolsEnvelope(type: "state.observation", payload: encodeJSON(snapshot)), on: connection)
            }
        }
        let cursor = onQueueSync { clients.values.filter { $0.subscriptions.contains(.timeline) }.map { $0.session.timelineSequence }.min() }
        guard let cursor, let snapshot = host.observation.timeline?(cursor) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            for client in self.clients.values where client.subscriptions.contains(.timeline) {
                self.sendTimeline(snapshot, to: client.connection)
            }
        }
    }

    @MainActor func syncTimelineCapture() {
        host.observation.capture?(hasSubscribers(for: .timeline))
    }
    func sendTimeline(_ snapshot: TimelineSnapshotPayload, to connection: any DevToolsConnection, id: Int? = nil) {
        guard let client = clients[ObjectIdentifier(connection)], client.subscriptions.contains(.timeline) else { return }
        let events = snapshot.events.filter { $0.sequence > client.session.timelineSequence }
        if let last = events.last { client.session.timelineSequence = last.sequence }
        guard id != nil || !events.isEmpty else { return }
        send(DevToolsEnvelope(type: "timeline.events", id: id,
            payload: encodeJSON(TimelineSnapshotPayload(events: events, dropped: snapshot.dropped))), on: connection)
    }

    public func broadcastMirrorFrame(_ frame: MirrorFramePayload) {
        guard hasSubscribers(for: .mirror) else { return }
        let env = DevToolsEnvelope(type: "mirror.frame", payload: encodeJSON(frame))
        send(env, toSubscribersOf: .mirror)
    }

    public func broadcastMirrorStopped(reason: String) {
        let env = DevToolsEnvelope(
            type: "mirror.stopped",
            payload: encodeJSON(MirrorStoppedPayload(reason: reason))
        )
        send(env, toSubscribersOf: .mirror)
    }

    // MARK: - Protocol dispatch

    func decodeAndDispatch(data: Data, on conn: any DevToolsConnection) {
        let env: DevToolsEnvelope
        do {
            env = try JSONDecoder().decode(DevToolsEnvelope.self, from: data)
        } catch {
            log("DevServer JSON decode failed: \(error)")
            return
        }
        guard let client = clients[ObjectIdentifier(conn)] else { return }
        if let error = client.session.validate(env) { send(error, on: conn); return }
        if env.type.hasPrefix("inspect.") {
            guard host.scene.inspect != nil else { sendError(for: env, on: conn, code: "unsupported", message: "Host has no scene editor"); return }
            let key = ObjectIdentifier(conn)
            guard inspectionOwner == nil || inspectionOwner == key else {
                sendError(for: env, on: conn, code: "busy", message: "Another inspector owns the temporary styles; disconnect it first"); return
            }
            if inspectionOwner == nil { inspectionOwner = key; inspectionLease = UUID() }
            selectionOwner = key
            let lease = inspectionLease!
            runOnHostMain { [weak self] in
                guard let self, self.onQueueSync({ self.clients[key] != nil && self.inspectionLease == lease && self.inspectionOwner == key }) else { return }
                if self.activeInspectionLease != lease {
                    if self.activeInspectionLease != nil { self.host.scene.reset?() }
                    self.activeInspectionLease = lease
                }
                if let response = self.host.scene.inspect?(env) { self.send(response, on: conn) }
            }
            return
        }
        switch env.type {
        case "diagnostics.tools", "diagnostics.call": dispatchDiagnostics(env, on: conn)
        case "state.list", "state.subscribe", "state.unsubscribe", "timeline.subscribe", "timeline.unsubscribe": dispatchObservation(env, on: conn)
        case "hello.ack", "tree.subscribe", "tree.unsubscribe", "select.node", "select.clear", "bye", "log.subscribe", "log.unsubscribe", "timing.subscribe", "timing.unsubscribe": dispatchScene(env, on: conn)
        case "mirror.start", "mirror.stop", "mirror.input", "mirror.activate": dispatchMirror(env, on: conn)
        case "state.checkpoint", "state.restore", "state.diff": dispatchCheckpoint(env, on: conn)
        case "input.record.start", "input.record.stop", "input.replay": dispatchRecording(env, on: conn)
        default:
            sendError(
                for: env,
                on: conn,
                code: "not_implemented",
                message: "unknown message type: \(env.type)"
            )
        }
    }

    func encodeTree(_ snapshot: TreeSnapshotPayload, type: String, id: Int? = nil,
                            completion: @escaping @Sendable (Data?) -> Void) {
        treeEncoder.submit { [weak self] in
            // The wire schema is unchanged. Going through JSONValue would
            // decode the entire recursive tree before encoding it again.
            let envelope = TreeEnvelope(type: type, id: id, payload: snapshot)
            do { completion(try JSONEncoder().encode(envelope)) }
            catch {
                self?.log("Unable to encode \(type): \(error)")
                completion(nil)
            }
        }
    }

    struct TreeEnvelope: Encodable {
        let type: String
        let id: Int?
        let payload: TreeSnapshotPayload
    }

    func sendHello(to conn: any DevToolsConnection) {
        let payload = HelloPayload(
            host: HelloHostInfo(
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                appTitle: config.appTitle,
                platform: currentPlatformName()
            ),
            capabilities: advertisedCapabilities
        )
        let env = DevToolsEnvelope(type: "hello", payload: encodeJSON(payload))
        send(env, on: conn)
    }

    func sendOK(for request: DevToolsEnvelope, on conn: any DevToolsConnection) {
        guard let env = DevToolsSession.ok(request) else { return }
        send(env, on: conn)
    }

    func sendError(for request: DevToolsEnvelope,
                           on conn: any DevToolsConnection,
                           code: String,
                           message: String) {
        let env = DevToolsEnvelope(
            type: request.type + ".err",
            id: request.id,
            payload: encodeJSON(ErrorPayload(code: code, message: message))
        )
        send(env, on: conn)
    }

    /// Queueing broadcasts instead of synchronously re-entering `queue` is
    /// essential: DevServer's own Logger can be routed through the central pipeline while
    /// already executing on this queue.
    func send(_ env: DevToolsEnvelope, toSubscribersOf subscription: Subscription) {
        queue.async { [weak self] in
            guard let self else { return }
            for client in self.clients.values where client.subscriptions.contains(subscription) {
                self.send(env, on: client.connection)
            }
        }
    }

    func send(_ env: DevToolsEnvelope, on conn: any DevToolsConnection) {
        let data: Data
        do {
            data = try JSONEncoder().encode(env)
        } catch {
            log("DevServer encode failed: \(error)")
            return
        }
        conn.send(text: data)
    }

    // MARK: - Misc

    func runOnHostMain(_ operation: @escaping @MainActor () -> Void) {
        if let execute = host.execute {
            execute(operation)
        } else {
            Task { @MainActor in
                operation()
            }
        }
    }

    @discardableResult
    func setSubscription(_ subscription: Subscription,
                                 enabled: Bool,
                                 for connection: any DevToolsConnection) -> Bool {
        let key = ObjectIdentifier(connection)
        guard let client = clients[key] else { return false }
        return client.session.set(subscription, enabled: enabled)
    }

    func hasSubscribers(for subscription: Subscription) -> Bool {
        onQueueSync {
            clients.values.contains { $0.subscriptions.contains(subscription) }
        }
    }

    func isSubscribed(_ subscription: Subscription,
                              connection: any DevToolsConnection) -> Bool {
        clients[ObjectIdentifier(connection)]?.subscriptions.contains(subscription) == true
    }

    func removeClient(_ connection: any DevToolsConnection) {
        let key = ObjectIdentifier(connection)
        let removed = clients.removeValue(forKey: key)
        let wasMirroring = removed?.subscriptions.contains(.mirror) == true
        if removed?.subscriptions.contains(.timeline) == true {
            runOnHostMain { [weak self] in self?.syncTimelineCapture() }
        }
        if inspectionOwner == key {
            let lease = inspectionLease!
            inspectionOwner = nil; inspectionLease = nil
            runOnHostMain { [weak self] in self?.resetInspection(lease: lease) }
        }
        if recordingOwner == key {
            recordingOwner = nil
            runOnHostMain { [weak self] in _ = self?.host.recording.stop?() }
        }
        if selectionOwner == key {
            selectionOwner = nil
            runOnHostMain { [weak self] in
                guard let self, self.onQueueSync({ self.selectionOwner == nil }) else { return }
                self.host.scene.clearSelection?()
            }
        }
        if wasMirroring, !clients.values.contains(where: { $0.subscriptions.contains(.mirror) }) {
            runOnHostMain { [weak self] in
                self?.host.mirror.stop?()
            }
        }
    }

    @MainActor func resetInspection(lease: UUID) {
        guard activeInspectionLease == lease else { return }
        activeInspectionLease = nil; host.scene.reset?()
    }

    func onQueueSync<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }

    func log(_ message: String) {
        logger.debug("\(message)")
    }

    func currentPlatformName() -> String {
        #if os(macOS)
        return "macOS"
        #elseif os(Linux)
        return "Linux"
        #elseif os(Windows)
        return "Windows"
        #else
        return "unknown"
        #endif
    }
}

/// Encode a Codable into JSONValue without going through Data twice in
/// the common path (only one round-trip — Codable → JSONValue, then the
/// envelope encodes the union).
@inline(__always)
func encodeJSON<T: Encodable>(_ value: T) -> JSONValue {
    do {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
        return .null
    }
}

/// Decode a JSONValue back to a concrete Codable. Returns nil on
/// missing or malformed payloads.
@inline(__always)
func decodePayload<T: Decodable>(_ type: T.Type, from value: JSONValue?) -> T? {
    guard let value else { return nil }
    do {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        return nil
    }
}
