import Foundation
#if canImport(Network)
import Network
#endif

/// Embedded TCP server on 127.0.0.1:9898.
/// Receives newline-delimited JSON commands from the guava-mcp CLI and
/// dispatches them to the registered handler on the main queue.
public final class MCPBridge: @unchecked Sendable {
    public static let port: UInt16 = 9898

    /// Called on the main queue: (action, params) → response dict.
    public var onCommand: ((String, [String: Any]) -> [String: Any])?

    #if canImport(Network)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private let queue = DispatchQueue.main
    #endif

    public init() {}

    public func start() {
        #if canImport(Network)
        queue.async { [weak self] in self?._start() }
        #endif
    }

    public func stop() {
        #if canImport(Network)
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.listener?.cancel()
            self?.connection = nil
            self?.listener = nil
        }
        #endif
    }

    #if canImport(Network)
    private func _start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: MCPBridge.port),
              let l = try? NWListener(using: params, on: nwPort)
        else { return }
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.queue.async { [weak self] in self?.accept(conn) }
        }
        l.start(queue: queue)
        self.listener = l
    }

    private func accept(_ conn: NWConnection) {
        connection?.cancel()
        connection = conn
        receiveBuffer = Data()
        conn.start(queue: queue)
        scheduleReceive(conn)
    }

    private func scheduleReceive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.drainBuffer(conn)
            }
            if !complete && error == nil {
                self.scheduleReceive(conn)
            }
        }
    }

    private func drainBuffer(_ conn: NWConnection) {
        while let newlineIndex = receiveBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = Data(receiveBuffer[receiveBuffer.startIndex..<newlineIndex])
            receiveBuffer = Data(receiveBuffer[receiveBuffer.index(after: newlineIndex)...])
            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let action = json["action"] as? String
            else { continue }
            let result = onCommand?(action, json) ?? ["ok": false, "error": "no handler registered"]
            guard var responseData = try? JSONSerialization.data(withJSONObject: result) else { continue }
            responseData.append(UInt8(ascii: "\n"))
            conn.send(content: responseData, completion: .idempotent)
        }
    }
    #endif
}
