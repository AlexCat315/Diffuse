import Foundation
import GuavaLogging

/// Drain diagnostics independently of the framed RPC stdout pipe.
final class PluginHostDiagnostics: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var pending = Data()
    private var processID: Int32 = 0

    func start(pid: Int32) {
        processID = pid
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            self?.consume(data, pid: pid, ending: data.isEmpty)
        }
    }
    func stop() { pipe.fileHandleForReading.readabilityHandler = nil; consume(Data(), pid: processID, ending: true) }
    deinit { stop() }

    private func consume(_ data: Data, pid: Int32, ending: Bool = false) {
        let lines = lock.withLock {
            pending.append(data)
            var lines: [Data] = []
            while let end = pending.firstIndex(of: 10) {
                lines.append(Data(pending[..<end])); pending.removeSubrange(...end)
            }
            if pending.count > 32768 || ending && !pending.isEmpty { lines.append(pending); pending.removeAll(keepingCapacity: true) }
            return lines
        }
        for line in lines where !line.isEmpty {
            LogSystem.logger("com.guava.engine.plugin.host").warning("\(String(decoding: line, as: UTF8.self))",
                metadata: ["child_pid": "\(pid)", "stream": "stderr"], source: "plugin.stderr")
        }
    }
}
