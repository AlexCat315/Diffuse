import Foundation
#if canImport(Network)
import Network
#endif
import GuavaUIRuntime
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

#if canImport(Network)

/// Lightweight WebSocket server that exposes the GuavaUI DevTools
/// protocol. Built on `Network.framework` so it has no third-party
/// dependencies.
///
/// The server is opt-in. AppRuntime constructs and starts it when an
/// AppConfig carries a non-nil DevToolsConfig.
public final class DevServer: @unchecked Sendable {

    private enum Subscription: Hashable {
        case tree
        case log
        case timing
        case mirror
    }

    private struct Client {
        let connection: NWConnection
        var subscriptions: Set<Subscription> = []
    }

    private let config: DevToolsConfig
    private let queue = DispatchQueue(label: "guava.devtools.server")
    private let queueKey = DispatchSpecificKey<Void>()
    private var listener: NWListener?
    /// Access only from `queue`. Keeping the connection and its subscriptions
    /// together prevents stale subscription state after disconnects.
    private var clients: [ObjectIdentifier: Client] = [:]
    private var selectionOwner: ObjectIdentifier?

    /// Capabilities announced in `hello`. DevTools configures this before
    /// start so clients do not expose controls with no host-side provider.
    public var advertisedCapabilities: [String] = ["tree", "select", "log", "timing"]

    /// Provided by AppRuntime; called on the main actor to build a
    /// snapshot when a tree request arrives.
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

    public init(config: DevToolsConfig) {
        self.config = config
        queue.setSpecific(key: queueKey, value: ())
    }

    public func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.allowLocalEndpointReuse = true

        // Bind to host. Network.framework treats `requiredInterfaceType = .loopback`
        // as the supported way to restrict to 127.0.0.1.
        if ["127.0.0.1", "localhost", "::1"].contains(config.host) {
            params.requiredInterfaceType = .loopback
        } else if !["0.0.0.0", "::", "*"].contains(config.host) {
            throw DevServerConfigurationError.unsupportedHost(config.host)
        }

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: config.port)!)
        listener.newConnectionHandler = { [weak self] conn in
            self?.acceptConnection(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        let shouldClearSelection = onQueueSync { selectionOwner != nil }
        onQueueSync {
            for client in clients.values { client.connection.cancel() }
            clients.removeAll()
            listener?.cancel()
            listener = nil
            selectionOwner = nil
        }
        if shouldClearSelection {
            runOnHostMain { [weak self] in
                self?.selectionClearHandler?()
            }
        }
    }

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

    // MARK: - Listener

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            log("DevServer listening on ws://\(config.host):\(config.port)")
        case .failed(let err):
            log("DevServer listener failed: \(err)")
        case .cancelled:
            log("DevServer listener cancelled")
        default:
            break
        }
    }

    private func acceptConnection(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        clients[key] = Client(connection: conn)

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                self.sendHello(to: conn)
                self.scheduleReceive(on: conn)
            case .failed(_), .cancelled:
                self.removeClient(conn)
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    // MARK: - Receive loop

    private func scheduleReceive(on conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, ctx, _, error in
            guard let self, let conn else { return }
            if let error {
                self.log("DevServer recv error: \(error)")
                conn.cancel()
                return
            }
            if let data, let ctx {
                self.handle(data: data, context: ctx, on: conn)
            }
            // Receive next message unless the connection is closing.
            if conn.state != .cancelled {
                self.scheduleReceive(on: conn)
            }
        }
    }

    private func handle(data: Data, context ctx: NWConnection.ContentContext, on conn: NWConnection) {
        guard let meta = ctx.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata else { return }
        switch meta.opcode {
        case .text:
            decodeAndDispatch(data: data, on: conn)
        case .binary:
            // v0.1 has no client-to-server binary frames.
            break
        case .close:
            conn.cancel()
        default:
            break
        }
    }

    private func decodeAndDispatch(data: Data, on conn: NWConnection) {
        let env: DevToolsEnvelope
        do {
            env = try JSONDecoder().decode(DevToolsEnvelope.self, from: data)
        } catch {
            log("DevServer JSON decode failed: \(error)")
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
            let nodeId = env.payload?.objectValue?["id"]?.stringValue
            if let nodeId {
                selectionOwner = ObjectIdentifier(conn)
                runOnHostMain { [weak self] in
                    self?.selectionHandler?(nodeId)
                }
                sendOK(for: env, on: conn)
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
                    self?.selectionClearHandler?()
                }
            }
            sendOK(for: env, on: conn)

        case "bye":
            conn.cancel()

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
                self?.stateRestoreHandler?(snapshot)
            }
            sendOK(for: env, on: conn)

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

    private func sendHello(to conn: NWConnection) {
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

    private func sendOK(for request: DevToolsEnvelope, on conn: NWConnection) {
        guard let id = request.id else { return }
        let env = DevToolsEnvelope(type: request.type + ".ok", id: id, payload: nil)
        send(env, on: conn)
    }

    private func sendError(for request: DevToolsEnvelope,
                           on conn: NWConnection,
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

    private func send(_ env: DevToolsEnvelope, on conn: NWConnection) {
        let data: Data
        do {
            data = try JSONEncoder().encode(env)
        } catch {
            log("DevServer encode failed: \(error)")
            return
        }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "guava.text", metadata: [meta])
        conn.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                if let error { self?.log("DevServer send error: \(error)") }
            }
        )
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
                                 for connection: NWConnection) -> Bool {
        let key = ObjectIdentifier(connection)
        guard var client = clients[key] else { return false }
        let changed: Bool
        if enabled {
            changed = client.subscriptions.insert(subscription).inserted
        } else {
            changed = client.subscriptions.remove(subscription) != nil
        }
        clients[key] = client
        return changed
    }

    private func hasSubscribers(for subscription: Subscription) -> Bool {
        onQueueSync {
            clients.values.contains { $0.subscriptions.contains(subscription) }
        }
    }

    private func isSubscribed(_ subscription: Subscription,
                              connection: NWConnection) -> Bool {
        clients[ObjectIdentifier(connection)]?.subscriptions.contains(subscription) == true
    }

    private func removeClient(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let wasMirroring = clients.removeValue(forKey: key)?.subscriptions.contains(.mirror) == true
        if selectionOwner == key {
            selectionOwner = nil
            runOnHostMain { [weak self] in
                self?.selectionClearHandler?()
            }
        }
        if wasMirroring, !clients.values.contains(where: { $0.subscriptions.contains(.mirror) }) {
            runOnHostMain { [weak self] in
                self?.mirrorStopHandler?()
            }
        }
    }

    private func onQueueSync<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return operation()
        }
        return queue.sync(execute: operation)
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

#else

/// Stub DevServer for platforms without Network.framework (Windows, Linux).
/// All methods are no-ops; the DevTools WebSocket server is not available.
public final class DevServer: @unchecked Sendable {
    public var advertisedCapabilities: [String] = ["tree", "select", "log", "timing"]
    public var snapshotProvider: SceneSnapshotProvider?
    public var selectionHandler: NodeSelectionHandler?
    public var selectionClearHandler: NodeSelectionClearHandler?
    public var mirrorStartHandler: (@MainActor (MirrorStartPayload) -> Void)?
    public var mirrorStopHandler: (@MainActor () -> Void)?
    public var mirrorInputHandler: (@MainActor (MirrorInputPayload) -> Void)?
    public var stateCheckpointHandler: (@MainActor () -> [String: String])?
    public var stateRestoreHandler: (@MainActor ([String: String]) -> Void)?
    public var hostMainExecutor: HostMainExecutor?

    public init(config: DevToolsConfig) {}
    public func start() throws {}
    public func stop() {}

    @MainActor
    public func broadcastTreeDelta() {}
    public func broadcastLog(_ entry: LogEntryPayload) {}
    public func broadcastTiming(_ frame: TimingFramePayload) {}
    public func broadcastMirrorFrame(_ frame: MirrorFramePayload) {}
    public func broadcastMirrorStopped(reason: String) {}
}

#endif
