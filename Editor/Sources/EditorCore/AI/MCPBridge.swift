import Foundation
#if canImport(Network)
import Network
#endif

/// Loopback-only JSON bridge. Clients have independent buffers and async handlers.
public final class MCPBridge: @unchecked Sendable {
    public static let port: UInt16 = 9898
    public static let maximumMessageBytes = 1_048_576
    public var onCommand: (@MainActor (String, [String: Any]) async -> [String: Any])?
    public private(set) var boundPort: UInt16?
    public private(set) var lastError: String?
    private let requestedPort: UInt16

    #if canImport(Network)
    private final class Client: @unchecked Sendable {
        let id = UUID()
        let connection: NWConnection
        var buffer = Data()
        var pendingLines: [Data] = []
        var processing = false
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private let queue = DispatchQueue.main
    #endif

    public init(port: UInt16? = nil) {
        requestedPort = port ?? ProcessInfo.processInfo.environment["GUAVA_MCP_PORT"]
            .flatMap(UInt16.init) ?? Self.port
    }

    public func start() {
        #if canImport(Network)
        queue.async { [weak self] in self?.startListener() }
        #else
        lastError = "The editor TCP bridge requires the Network framework on this platform."
        #endif
    }

    public func stop() {
        #if canImport(Network)
        queue.async { [weak self] in
            guard let self else { return }
            for client in self.clients.values { client.connection.cancel() }
            self.clients.removeAll()
            self.listener?.cancel()
            self.listener = nil
            self.boundPort = nil
        }
        #endif
    }

    #if canImport(Network)
    private func startListener() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: requestedPort)!)
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready: self.boundPort = listener?.port?.rawValue; self.lastError = nil
                case let .failed(error): self.lastError = error.localizedDescription; self.listener = nil
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                let client = Client(connection)
                self.clients[client.id] = client
                connection.start(queue: self.queue)
                self.receive(client)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch { lastError = error.localizedDescription }
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, self.clients[client.id] != nil else { return }
            if let data { client.buffer.append(data) }
            guard client.buffer.count <= Self.maximumMessageBytes else {
                self.close(client)
                return
            }
            while let newline = client.buffer.firstIndex(of: 10) {
                let line = Data(client.buffer[..<newline])
                client.buffer.removeSubrange(...newline)
                if !line.isEmpty { client.pendingLines.append(line) }
            }
            guard client.pendingLines.count <= 64 else { self.close(client); return }
            self.processNext(client)
            if complete || error != nil { self.close(client) }
            else { self.receive(client) }
        }
    }

    private func processNext(_ client: Client) {
        guard !client.processing, !client.pendingLines.isEmpty else { return }
        let data = client.pendingLines.removeFirst()
        client.processing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result: [String: Any]
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let action = json["action"] as? String {
                result = await self.onCommand?(action, json) ?? ["ok": false, "error": "editor handler unavailable"]
            } else { result = ["ok": false, "error": "invalid JSON command"] }
            self.send(result, to: client)
            client.processing = false
            if self.clients[client.id] != nil { self.processNext(client) }
        }
    }

    private func send(_ result: [String: Any], to client: Client) {
        guard var data = try? JSONSerialization.data(withJSONObject: result) else { return }
        data.append(10)
        client.connection.send(content: data, completion: .idempotent)
    }

    private func close(_ client: Client) {
        clients.removeValue(forKey: client.id)
        client.connection.cancel()
    }
    #endif
}
