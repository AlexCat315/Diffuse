import Foundation
import Network
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

    public init(host: String = "127.0.0.1",
                port: UInt16 = 9229,
                appTitle: String = "GuavaUI",
                enabled: Bool = true) {
        self.host = host
        self.port = port
        self.appTitle = appTitle
        self.enabled = enabled
    }

    /// Convenience: enables the server when the `GUAVA_DEVTOOLS=1` env var is set.
    public static func fromEnvironment(appTitle: String = "GuavaUI") -> DevToolsConfig? {
        let env = ProcessInfo.processInfo.environment
        guard env["GUAVA_DEVTOOLS"] == "1" else { return nil }
        let host = env["GUAVA_DEVTOOLS_HOST"] ?? "127.0.0.1"
        let port = env["GUAVA_DEVTOOLS_PORT"].flatMap(UInt16.init) ?? 9229
        return DevToolsConfig(host: host, port: port, appTitle: appTitle, enabled: true)
    }
}

/// Closure that produces a tree snapshot. The host runtime is responsible
/// for invoking the closure on the main actor / scene thread before the
/// JSON encode happens.
public typealias SceneSnapshotProvider = @MainActor () -> TreeSnapshotPayload

/// Closure invoked when the client requests `select.node`. The host
/// runtime decides what "selecting" means (e.g. drawing an overlay).
public typealias NodeSelectionHandler = @MainActor (_ id: String) -> Void

/// Lightweight WebSocket server that exposes the GuavaUI DevTools
/// protocol. Built on `Network.framework` so it has no third-party
/// dependencies.
///
/// The server is opt-in. AppRuntime constructs and starts it when an
/// AppConfig carries a non-nil DevToolsConfig.
public final class DevServer: @unchecked Sendable {

    private let config: DevToolsConfig
    private let queue = DispatchQueue(label: "guava.devtools.server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]

    /// Provided by AppRuntime; called on the main actor to build a
    /// snapshot when a tree request arrives.
    public var snapshotProvider: SceneSnapshotProvider?

    /// Provided by AppRuntime; called on the main actor when the client
    /// asks to highlight a node.
    public var selectionHandler: NodeSelectionHandler?

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

    #if canImport(Logging)
    private let log = Logger(label: "guava.devtools")
    #endif

    public init(config: DevToolsConfig) {
        self.config = config
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
        if config.host == "127.0.0.1" || config.host == "localhost" {
            params.requiredInterfaceType = .loopback
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
        queue.sync {
            for conn in clients.values { conn.cancel() }
            clients.removeAll()
            listener?.cancel()
            listener = nil
        }
    }

    /// Push a `tree.delta` to every connected client. Safe to call from
    /// the main actor; encoding happens synchronously.
    @MainActor
    public func broadcastTreeDelta() {
        guard let snapshot = snapshotProvider?() else { return }
        let env = DevToolsEnvelope(
            type: "tree.delta",
            payload: encodeJSON(snapshot)
        )
        sendToAll(env)
    }

    public func broadcastLog(_ entry: LogEntryPayload) {
        let env = DevToolsEnvelope(type: "log.entry", payload: encodeJSON(entry))
        sendToAll(env)
    }

    public func broadcastTiming(_ frame: TimingFramePayload) {
        let env = DevToolsEnvelope(type: "timing.frame", payload: encodeJSON(frame))
        sendToAll(env)
    }

    public func broadcastMirrorFrame(_ frame: MirrorFramePayload) {
        let env = DevToolsEnvelope(type: "mirror.frame", payload: encodeJSON(frame))
        sendToAll(env)
    }

    public func broadcastMirrorStopped(reason: String) {
        let env = DevToolsEnvelope(
            type: "mirror.stopped",
            payload: encodeJSON(MirrorStoppedPayload(reason: reason))
        )
        sendToAll(env)
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
        clients[key] = conn

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn else { return }
            switch state {
            case .ready:
                self.sendHello(to: conn)
                self.scheduleReceive(on: conn)
            case .failed(_), .cancelled:
                self.clients.removeValue(forKey: ObjectIdentifier(conn))
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
            Task { @MainActor [weak self] in
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
            // No state to clean up in v0.1 — every client receives every delta.
            sendOK(for: env, on: conn)

        case "select.node":
            let nodeId = env.payload?.objectValue?["id"]?.stringValue
            if let nodeId {
                Task { @MainActor [weak self] in
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

        case "bye":
            conn.cancel()

        case "log.subscribe", "log.unsubscribe",
             "timing.subscribe", "timing.unsubscribe":
            // v0.1: every client receives every log/timing message; the
            // subscribe/unsubscribe pair is reserved for forward-compat.
            sendOK(for: env, on: conn)

        case "mirror.start":
            let payload = decodePayload(MirrorStartPayload.self, from: env.payload)
                ?? MirrorStartPayload(fps: nil, quality: nil)
            log.info("recv mirror.start fps=\(payload.fps ?? -1) quality=\(payload.quality ?? -1) handlerWired=\(mirrorStartHandler != nil)")
            print("[guava.devtools] dispatching mirror.start Task")
            Task { @MainActor [weak self] in
                print("[guava.devtools] mirror.start Task body running, handler=\((self?.mirrorStartHandler) == nil ? "nil" : "set")")
                self?.mirrorStartHandler?(payload)
            }
            sendOK(for: env, on: conn)

        case "mirror.stop":
            log.info("recv mirror.stop handlerWired=\(mirrorStopHandler != nil)")
            Task { @MainActor [weak self] in
                self?.mirrorStopHandler?()
            }
            sendOK(for: env, on: conn)

        case "mirror.input":
            if let input = decodePayload(MirrorInputPayload.self, from: env.payload) {
                Task { @MainActor [weak self] in
                    self?.mirrorInputHandler?(input)
                }
            } else {
                sendError(for: env, on: conn,
                          code: "bad_request",
                          message: "mirror.input requires payload")
            }

        case "state.checkpoint":
            Task { @MainActor [weak self] in
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
            let snapshot = (env.payload?.objectValue ?? [:]).compactMapValues { $0.stringValue }
            Task { @MainActor [weak self] in
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
            capabilities: ["tree", "select", "log", "timing", "mirror", "state"]
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

    private func sendToAll(_ env: DevToolsEnvelope) {
        let connections = queue.sync { Array(clients.values) }
        for conn in connections { send(env, on: conn) }
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
