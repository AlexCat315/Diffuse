#if os(macOS) || os(Linux) || os(Windows)
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
        let handle = pipe.fileHandleForReading
        let reader = Thread { [weak self] in
            do {
                while let data = try handle.read(upToCount: 4096), !data.isEmpty {
                    self?.consume(data, pid: pid)
                }
            } catch {}
            self?.consume(Data(), pid: pid, ending: true)
        }
        reader.name = "guava.plugin.stderr"
        reader.start()
    }
    func stop() {
        try? pipe.fileHandleForReading.close()
        consume(Data(), pid: processID, ending: true)
    }
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

#endif
