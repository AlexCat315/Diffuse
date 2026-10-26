#if os(macOS) || os(Linux) || os(Windows)
import Foundation
private import CoveLogging

/// Line framing for stderr chunks delivered by the shared process service.
final class PluginHostDiagnostics {
    private var pending = Data()
    private var processID: Int32 = 0

    func finish() {
        consume(Data(), pid: processID, ending: true)
    }

    func consume(_ data: Data, pid: Int32, ending: Bool = false) {
        processID = pid
        let lines: [Data] = {
            pending.append(data)
            var lines: [Data] = []
            while let end = pending.firstIndex(of: 10) {
                lines.append(Data(pending[..<end])); pending.removeSubrange(...end)
            }
            if pending.count > 32768 || ending && !pending.isEmpty { lines.append(pending); pending.removeAll(keepingCapacity: true) }
            return lines
        }()
        for line in lines where !line.isEmpty {
            LogSystem.logger("com.cove.engine.plugin.host").warning("\(String(decoding: line, as: UTF8.self))",
                metadata: ["child_pid": "\(pid)", "stream": "stderr"], source: "plugin.stderr")
        }
    }
}

#endif
