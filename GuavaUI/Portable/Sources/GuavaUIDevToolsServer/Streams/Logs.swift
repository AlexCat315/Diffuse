import Foundation
import GuavaLogging
import GuavaUIDevToolsProtocol

/// One bounded handoff from the log writer to the socket queue. Neither queue waits on the other.
final class DevToolsLogFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [LogRecord] = []
    private var scheduled = false
    private var dropped: UInt64 = 0
    private var observation: LogObservation?

    func start(_ server: DevServer) {
        observation = LogSystem.observe(replay: false) { [weak server] record in server?.broadcastLog(record) }
    }
    func stop() { observation?.cancel(); observation = nil; lock.withLock { pending.removeAll(); dropped = 0; scheduled = false } }
    func enqueue(_ record: LogRecord, server: DevServer) {
        let schedule = lock.withLock { () -> Bool in
            guard pending.count < 1024 else { dropped &+= 1; return false }
            pending.append(record)
            if scheduled { return false }; scheduled = true; return true
        }
        if schedule { server.queue.async { [weak server, weak self] in if let server { self?.drain(server) } } }
    }
    static func snapshot(_ query: LogQuery) -> LogSnapshot {
        let snapshot = LogSystem.snapshot(query)
        var records: [LogRecord] = [], bytes = 0
        let encoder = JSONEncoder()
        for record in snapshot.records.suffix(200).reversed() {
            guard let data = try? encoder.encode(record), bytes + data.count <= 512 * 1024 else { break }
            bytes += data.count; records.append(record)
        }
        return LogSnapshot(records: records.reversed(), dropped: snapshot.dropped, firstAvailableSequence: snapshot.firstAvailableSequence)
    }
    private func drain(_ server: DevServer) {
        let batch = lock.withLock { () -> ([LogRecord], UInt64) in
            let batch = pending, loss = dropped; pending = []; dropped = 0; scheduled = false; return (batch, loss)
        }
        guard server.isStarted else { return }
        for key in Array(server.clients.keys) {
            guard let client = server.clients[key], client.subscriptions.contains(.log) else { continue }
            var loss = batch.1
            for record in batch.0 where record.sequence > client.session.logSequence && client.session.logQuery.matches(record) {
                client.session.logSequence = record.sequence
                guard client.connection.isWritable else { loss &+= 1; continue }
                server.send(.init(type: "log.entry", payload: DevToolsCodec.json(record)), on: client.connection)
            }
            client.session.logDropped &+= loss
            if client.session.logDropped > 0, client.connection.isWritable {
                server.send(.init(type: "log.gap", payload: .object(["dropped": .number(Double(client.session.logDropped))])), on: client.connection)
                client.session.logDropped = 0
            }
        }
    }
}
