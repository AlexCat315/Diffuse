import Foundation
import Dispatch
import GuavaUIDevToolsProtocol
#if canImport(Logging)
import Logging
#endif

/// Configuration for the in-process DevTools WebSocket server.
public struct DevToolsConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var appTitle: String
    public var enabled: Bool
    /// Automatically bootstraps swift-log with LogTap. Disable this when the
    /// host already bootstraps LoggingSystem and multiplex LogTap manually.
    public var autoInstallLogTap: Bool

    public init(host: String = "127.0.0.1",
                port: UInt16 = 9229,
                appTitle: String = "GuavaUI",
                enabled: Bool = true,
                autoInstallLogTap: Bool = true) {
        self.host = host
        self.port = port
        self.appTitle = appTitle
        self.enabled = enabled
        self.autoInstallLogTap = autoInstallLogTap
    }

    /// Convenience: enables the server when the `GUAVA_DEVTOOLS=1` env var is set.
    public static func fromEnvironment(appTitle: String = "GuavaUI") -> DevToolsConfig? {
        let env = ProcessInfo.processInfo.environment
        guard env["GUAVA_DEVTOOLS"] == "1" else { return nil }
        let host = env["GUAVA_DEVTOOLS_HOST"] ?? "127.0.0.1"
        let port = env["GUAVA_DEVTOOLS_PORT"].flatMap(UInt16.init) ?? 9229
        let autoInstallLogTap = env["GUAVA_DEVTOOLS_AUTO_LOG_TAP"] != "0"
        return DevToolsConfig(host: host,
                              port: port,
                              appTitle: appTitle,
                              enabled: true,
                              autoInstallLogTap: autoInstallLogTap)
    }
}

public enum DevServerConfigurationError: LocalizedError {
    case unsupportedHost(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHost(let host):
            return "Unsupported DevTools host '\(host)'. Use localhost/127.0.0.1/::1 for loopback or 0.0.0.0/:: for all interfaces."
        }
    }
}

/// Closure that produces a tree snapshot. The host runtime is responsible
/// for invoking the closure on the main actor / scene thread before the
/// JSON encode happens.
public typealias SceneSnapshotProvider = @MainActor () -> TreeSnapshotPayload

/// Closure invoked when the client requests `select.node`. The host
/// runtime decides what "selecting" means (e.g. drawing an overlay).
public typealias NodeSelectionHandler = @MainActor (_ id: String) -> Void
public typealias NodeSelectionClearHandler = @MainActor () -> Void

/// Schedules DevTools callbacks onto the host's UI thread. AppRuntime uses its
/// own main-thread inbox because its SDL loop is synchronous and may not yield
/// to Swift Concurrency `MainActor` tasks while running.
public typealias HostMainExecutor = (@escaping @MainActor () -> Void) -> Void

/// WebSocket server with platform-independent protocol dispatch.
/// The transport owns sockets; the host owns UI-thread scheduling.
///
/// The server is opt-in. AppRuntime constructs and starts it when an
/// AppConfig carries a non-nil DevToolsConfig.
public final class DevServer: @unchecked Sendable {

    private typealias Subscription = DevToolsSubscription
    private struct Client {
        let connection: any DevToolsConnection
        let session = DevToolsSession()
        var subscriptions: Set<Subscription> { session.subscriptions }
    }

    private let config: DevToolsConfig
    private let queue = DispatchQueue(label: "guava.devtools.server")
    private let queueKey = DispatchSpecificKey<Void>()
    private let transport: any DevToolsTransport
    private var isStarted = false
    private var generation: UInt64 = 0

    /// Actual bound port, including when configured with port zero.
    public var boundPort: UInt16? { transport.boundPort }
    /// Access only from `queue`. Keeping the connection and its subscriptions
    /// together prevents stale subscription state after disconnects.
    private var clients: [ObjectIdentifier: Client] = [:]
    private var recordingOwner: ObjectIdentifier?
    private var selectionOwner: ObjectIdentifier?
    private var inspectionOwner: ObjectIdentifier?
    private var inspectionLease: UUID?
    @MainActor private var activeInspectionLease: UUID?
    public var inspectionHandler: (@MainActor (DevToolsEnvelope) -> DevToolsEnvelope)?
    public var inspectionResetHandler: (@MainActor () -> Void)?

    /// Capabilities announced in `hello`. DevTools configures this before
    /// start so clients do not expose controls with no host-side provider.
    public var advertisedCapabilities: [String] = ["tree", "select", "log", "timing"]

    /// Provided by AppRuntime; called on the main actor to build a
    /// snapshot when a tree request arrives.
    public var stateRestoreResultHandler: (@MainActor ([String: String]) -> Bool)?
    public var recordingStartHandler: (@MainActor () -> Bool)?
    public var recordingStopHandler: (@MainActor () -> InputRecording?)?
    public var recordingReplayHandler: (@MainActor (InputRecording) -> Bool)?
    public var snapshotProvider: SceneSnapshotProvider?

    /// Provided by AppRuntime; called on the main actor when the client
    /// asks to highlight a node.
    public var selectionHandler: NodeSelectionHandler?
    public var selectionClearHandler: NodeSelectionClearHandler?

    /// Forwarded mirror.start request → host runtime.
    public var mirrorStartHandler: (@MainActor (MirrorStartPayload) -> Void)?
    /// Forwarded mirror.stop request → host runtime.
    public var mirrorStopHandler: (@MainActor () -> Void)?
    /// Forwarded mirror.input event → host runtime.
    public var mirrorInputHandler: (@MainActor (MirrorInputPayload) -> Void)?

    /// Forwarded state.checkpoint request → host runtime. The result is
    /// returned as `state.checkpoint.ok` with the snapshot payload.
    public var stateCheckpointHandler: (@MainActor () -> [String: String])?
    /// Forwarded state.restore request → host runtime.
    public var stateRestoreHandler: (@MainActor ([String: String]) -> Void)?

    /// Optional host scheduler for callbacks that need UI-thread state.
    /// Falls back to `Task { @MainActor ... }` for tests and non-SDL hosts.
    public var hostMainExecutor: HostMainExecutor?

    #if canImport(Logging)
    private let log = Logger(label: "guava.devtools")
    #endif

    public init(config: DevToolsConfig, transport: any DevToolsTransport = NIODevToolsTransport()) {
        self.config = config
        self.transport = transport
        queue.setSpecific(key: queueKey, value: ())
    }

    public func start() throws {
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
        log("DevServer listening on ws://\(config.host):\(boundPort ?? config.port)")
    }

    public func stop() {
        let cleanup = onQueueSync { () -> (Bool, Bool, Bool, UUID?) in
            generation &+= 1
            isStarted = false
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
        if cleanup.0 || cleanup.1 || cleanup.2 || cleanup.3 != nil {
            runOnHostMain { [weak self] in
                if cleanup.0, let self, self.onQueueSync({ self.selectionOwner == nil }) { self.selectionClearHandler?() }
                if cleanup.1 { self?.mirrorStopHandler?() }
                if cleanup.2 { _ = self?.recordingStopHandler?() }
                if let lease = cleanup.3 { self?.resetInspection(lease: lease) }
            }
        }
    }

    deinit { transport.stop() }

    /// Push a `tree.delta` to every connected client. Safe to call from
    /// the main actor; encoding happens synchronously.
    @MainActor
    public func broadcastTreeDelta() {
        // A snapshot walks the complete live tree, so do not pay that cost
        // merely because DevTools is enabled.
        guard hasSubscribers(for: .tree) else { return }
        guard let snapshot = snapshotProvider?() else { return }
        let env = DevToolsEnvelope(
            type: "tree.delta",
            payload: encodeJSON(snapshot)
        )
        send(env, toSubscribersOf: .tree)
    }

    public func broadcastLog(_ entry: LogEntryPayload) {
        guard hasSubscribers(for: .log) else { return }
        let env = DevToolsEnvelope(type: "log.entry", payload: encodeJSON(entry))
        send(env, toSubscribersOf: .log)
    }

    public func broadcastTiming(_ frame: TimingFramePayload) {
        guard hasSubscribers(for: .timing) else { return }
        let env = DevToolsEnvelope(type: "timing.frame", payload: encodeJSON(frame))
        send(env, toSubscribersOf: .timing)
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

    private func decodeAndDispatch(data: Data, on conn: any DevToolsConnection) {
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
            guard inspectionHandler != nil else { sendError(for: env, on: conn, code: "unsupported", message: "Host has no scene editor"); return }
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
                    if self.activeInspectionLease != nil { self.inspectionResetHandler?() }
                    self.activeInspectionLease = lease
                }
                if let response = self.inspectionHandler?(env) { self.send(response, on: conn) }
            }
            return
        }
        switch env.type {
        case "hello.ack":
            // Nothing to do — capabilities negotiation is one-way for now.
            break

        case "tree.subscribe":
            setSubscription(.tree, enabled: true, for: conn)
            runOnHostMain { [weak self] in
                guard let self else { return }
                let snap = self.snapshotProvider?() ?? TreeSnapshotPayload(root: nil)
                let response = DevToolsEnvelope(
                    type: "tree.snapshot",
                    id: env.id,
                    payload: encodeJSON(snap)
                )
                self.send(response, on: conn)
            }

        case "tree.unsubscribe":
            setSubscription(.tree, enabled: false, for: conn)
            sendOK(for: env, on: conn)

        case "select.node":
            if let owner = inspectionOwner, owner != ObjectIdentifier(conn) {
                sendError(for: env, on: conn, code: "busy", message: "Another inspector owns the scene editor"); return
            }
            let nodeId = env.payload?.objectValue?["id"]?.stringValue
            if let nodeId {
                selectionOwner = ObjectIdentifier(conn)
                runOnHostMain { [weak self] in
                    guard let self, self.onQueueSync({ self.selectionOwner == ObjectIdentifier(conn) && self.clients[ObjectIdentifier(conn)] != nil }) else { return }
                    self.selectionHandler?(nodeId)
                    self.sendOK(for: env, on: conn)
                }
            } else {
                sendError(
                    for: env,
                    on: conn,
                    code: "bad_request",
                    message: "select.node requires payload.id"
                )
            }

        case "select.clear":
            let key = ObjectIdentifier(conn)
            if selectionOwner == key {
                selectionOwner = nil
                runOnHostMain { [weak self] in
                    guard let self, self.onQueueSync({ self.selectionOwner == nil }) else { return }
                    self.selectionClearHandler?()
                }
            }
            sendOK(for: env, on: conn)

        case "bye":
            conn.close()

        case "log.subscribe":
            setSubscription(.log, enabled: true, for: conn)
            sendOK(for: env, on: conn)

        case "log.unsubscribe":
            setSubscription(.log, enabled: false, for: conn)
            sendOK(for: env, on: conn)

        case "timing.subscribe":
            setSubscription(.timing, enabled: true, for: conn)
            sendOK(for: env, on: conn)

        case "timing.unsubscribe":
            setSubscription(.timing, enabled: false, for: conn)
            sendOK(for: env, on: conn)

        case "mirror.start":
            let payload: MirrorStartPayload
            if let rawPayload = env.payload {
                guard let decoded = decodePayload(MirrorStartPayload.self, from: rawPayload) else {
                    sendError(for: env, on: conn,
                              code: "bad_request",
                              message: "mirror.start payload is malformed")
                    return
                }
                payload = decoded
            } else {
                payload = MirrorStartPayload(fps: nil, quality: nil)
            }
            setSubscription(.mirror, enabled: true, for: conn)
            log.info("recv mirror.start fps=\(payload.fps ?? -1) quality=\(payload.quality ?? -1)")
            runOnHostMain { [weak self] in
                self?.mirrorStartHandler?(payload)
            }
            sendOK(for: env, on: conn)

        case "mirror.stop":
            let shouldStopCapture = setSubscription(.mirror, enabled: false, for: conn)
                && !hasSubscribers(for: .mirror)
            log.info("recv mirror.stop handlerWired=\(mirrorStopHandler != nil) stopCapture=\(shouldStopCapture)")
            if shouldStopCapture {
                runOnHostMain { [weak self] in
                    self?.mirrorStopHandler?()
                }
            }
            sendOK(for: env, on: conn)

        case "mirror.input":
            guard isSubscribed(.mirror, connection: conn) else {
                sendError(for: env, on: conn,
                          code: "invalid_state",
                          message: "mirror.input requires an active mirror subscription")
                return
            }
            if let input = decodePayload(MirrorInputPayload.self, from: env.payload) {
                runOnHostMain { [weak self] in
                    self?.mirrorInputHandler?(input)
                }
                sendOK(for: env, on: conn)
            } else {
                sendError(for: env, on: conn,
                          code: "bad_request",
                          message: "mirror.input requires payload")
            }

        case "state.checkpoint":
            runOnHostMain { [weak self] in
                guard let self else { return }
                let snapshot = self.stateCheckpointHandler?() ?? [:]
                let response = DevToolsEnvelope(
                    type: "state.checkpoint.ok",
                    id: env.id,
                    payload: encodeJSON(snapshot)
                )
                self.send(response, on: conn)
            }

        case "state.restore":
            guard let object = env.payload?.objectValue,
                  object.values.allSatisfy({ $0.stringValue != nil }) else {
                sendError(for: env, on: conn,
                          code: "bad_request",
                          message: "state.restore requires an object with string values")
                return
            }
            let snapshot = object.compactMapValues(\.stringValue)
            runOnHostMain { [weak self] in
                guard let self else { return }
                if let restore = self.stateRestoreResultHandler {
                    if restore(snapshot) { self.sendOK(for: env, on: conn) }
                    else { self.sendError(for: env, on: conn, code: "bad_request", message: "Host rejected checkpoint state") }
                } else { self.stateRestoreHandler?(snapshot); self.sendOK(for: env, on: conn) }
            }

        case "state.diff":
            let before = DevToolsSession.state(env.payload)!
            runOnHostMain { [weak self] in
                guard let self else { return }
                let diff = StateDifference(before: before, after: self.stateCheckpointHandler?() ?? [:])
                self.send(DevToolsEnvelope(type: "state.diff.ok", id: env.id, payload: DevToolsCodec.json(diff)), on: conn)
            }

        case "input.record.start":
            guard recordingOwner == nil, recordingStartHandler != nil else {
                sendError(for: env, on: conn, code: "invalid_state", message: "Recording unavailable or already active"); return
            }
            recordingOwner = ObjectIdentifier(conn)
            runOnHostMain { [weak self] in
                guard let self else { return }
                if self.recordingStartHandler?() == true { self.sendOK(for: env, on: conn) }
                else {
                    self.queue.async { self.recordingOwner = nil }
                    self.sendError(for: env, on: conn, code: "invalid_state", message: "Host could not start recording")
                }
            }

        case "input.record.stop":
            guard recordingOwner == ObjectIdentifier(conn) else {
                sendError(for: env, on: conn, code: "invalid_state", message: "This connection does not own a recording"); return
            }
            recordingOwner = nil
            runOnHostMain { [weak self] in
                guard let self else { return }
                if let recording = self.recordingStopHandler?() {
                    self.send(DevToolsEnvelope(type: "input.record.stop.ok", id: env.id, payload: DevToolsCodec.json(recording)), on: conn)
                } else { self.sendError(for: env, on: conn, code: "invalid_state", message: "No recording") }
            }

        case "input.replay":
            guard recordingOwner == nil, recordingReplayHandler != nil else {
                sendError(for: env, on: conn, code: "invalid_state", message: "Stop recording before replaying"); return
            }
            let recording = DevToolsCodec.decode(InputRecording.self, env.payload)!
            runOnHostMain { [weak self] in
                guard let self else { return }
                if self.recordingReplayHandler?(recording) == true { self.sendOK(for: env, on: conn) }
                else { self.sendError(for: env, on: conn, code: "bad_request", message: "Host rejected recording state") }
            }

        default:
            sendError(
                for: env,
                on: conn,
                code: "not_implemented",
                message: "unknown message type: \(env.type)"
            )
        }
    }

    // MARK: - Send helpers

    private func sendHello(to conn: any DevToolsConnection) {
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

    private func sendOK(for request: DevToolsEnvelope, on conn: any DevToolsConnection) {
        guard let env = DevToolsSession.ok(request) else { return }
        send(env, on: conn)
    }

    private func sendError(for request: DevToolsEnvelope,
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
    /// essential: DevServer's own Logger can be routed through LogTap while
    /// already executing on this queue.
    private func send(_ env: DevToolsEnvelope, toSubscribersOf subscription: Subscription) {
        queue.async { [weak self] in
            guard let self else { return }
            for client in self.clients.values where client.subscriptions.contains(subscription) {
                self.send(env, on: client.connection)
            }
        }
    }

    private func send(_ env: DevToolsEnvelope, on conn: any DevToolsConnection) {
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

    private func runOnHostMain(_ operation: @escaping @MainActor () -> Void) {
        if let hostMainExecutor {
            hostMainExecutor(operation)
        } else {
            Task { @MainActor in
                operation()
            }
        }
    }

    @discardableResult
    private func setSubscription(_ subscription: Subscription,
                                 enabled: Bool,
                                 for connection: any DevToolsConnection) -> Bool {
        let key = ObjectIdentifier(connection)
        guard let client = clients[key] else { return false }
        return client.session.set(subscription, enabled: enabled)
    }

    private func hasSubscribers(for subscription: Subscription) -> Bool {
        onQueueSync {
            clients.values.contains { $0.subscriptions.contains(subscription) }
        }
    }

    private func isSubscribed(_ subscription: Subscription,
                              connection: any DevToolsConnection) -> Bool {
        clients[ObjectIdentifier(connection)]?.subscriptions.contains(subscription) == true
    }

    private func removeClient(_ connection: any DevToolsConnection) {
        let key = ObjectIdentifier(connection)
        let wasMirroring = clients.removeValue(forKey: key)?.subscriptions.contains(.mirror) == true
        if inspectionOwner == key {
            let lease = inspectionLease!
            inspectionOwner = nil; inspectionLease = nil
            runOnHostMain { [weak self] in self?.resetInspection(lease: lease) }
        }
        if recordingOwner == key {
            recordingOwner = nil
            runOnHostMain { [weak self] in _ = self?.recordingStopHandler?() }
        }
        if selectionOwner == key {
            selectionOwner = nil
            runOnHostMain { [weak self] in
                guard let self, self.onQueueSync({ self.selectionOwner == nil }) else { return }
                self.selectionClearHandler?()
            }
        }
        if wasMirroring, !clients.values.contains(where: { $0.subscriptions.contains(.mirror) }) {
            runOnHostMain { [weak self] in
                self?.mirrorStopHandler?()
            }
        }
    }

    @MainActor private func resetInspection(lease: UUID) {
        guard activeInspectionLease == lease else { return }
        activeInspectionLease = nil; inspectionResetHandler?()
    }

    private func onQueueSync<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }

    private func log(_ message: String) {
        #if canImport(Logging)
        log.info("\(message)")
        #else
        print("[guava.devtools] \(message)")
        #endif
    }

    private func currentPlatformName() -> String {
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
private func encodeJSON<T: Encodable>(_ value: T) -> JSONValue {
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
private func decodePayload<T: Decodable>(_ type: T.Type, from value: JSONValue?) -> T? {
    guard let value else { return nil }
    do {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        return nil
    }
}
