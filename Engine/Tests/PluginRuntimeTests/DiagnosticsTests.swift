import Foundation
import Testing
import CoveLogging
@testable import PluginRuntime

private final class DiagnosticRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [LogRecord] = []
    func append(_ record: LogRecord) { lock.withLock { records.append(record) } }
    var values: [LogRecord] { lock.withLock { records } }
}

@Test func pluginDiagnosticsFrameFragmentedChunksAndKeepTheFinalPartialLine() {
    let marker = UUID().uuidString
    let captured = DiagnosticRecords()
    let observation = LogSystem.observe(query: .init { $0.text = marker }, replay: false) { captured.append($0) }
    defer { observation.cancel() }
    let diagnostics = PluginHostDiagnostics()
    let data = Data(((0..<500).map { "\(marker) \($0) " + String(repeating: "x", count: 200) }.joined(separator: "\n") + "\n\(marker) final").utf8)
    for offset in stride(from: 0, to: data.count, by: 137) {
        diagnostics.consume(data.subdata(in: offset..<min(offset + 137, data.count)), pid: 42)
    }
    diagnostics.finish()
    LogSystem.flush()
    #expect(captured.values.count == 501)
    #expect(captured.values.last?.message == "\(marker) final")
    #expect(captured.values.allSatisfy { $0.metadata["child_pid"] == .string("42") })
}
