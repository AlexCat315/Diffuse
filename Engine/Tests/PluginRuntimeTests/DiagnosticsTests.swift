import Foundation
import Testing
import GuavaLogging
@testable import PluginRuntime

private final class DiagnosticRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [LogRecord] = []
    func append(_ record: LogRecord) { lock.withLock { records.append(record) } }
    var values: [LogRecord] { lock.withLock { records } }
}

@Test func pluginDiagnosticsDrainBeyondPipeCapacityAndKeepTheFinalPartialLine() async throws {
    let marker = UUID().uuidString
    let captured = DiagnosticRecords()
    let observation = LogSystem.observe(query: .init { $0.text = marker }, replay: false) { captured.append($0) }
    defer { observation.cancel() }
    let diagnostics = PluginHostDiagnostics(); diagnostics.start(pid: 42)
    defer { diagnostics.stop() }
    let data = Data(((0..<500).map { "\(marker) \($0) " + String(repeating: "x", count: 200) }.joined(separator: "\n") + "\n\(marker) final").utf8)
    let writer = Task.detached {
        try diagnostics.pipe.fileHandleForWriting.write(contentsOf: data)
        try diagnostics.pipe.fileHandleForWriting.close()
    }
    try await writer.value
    let deadline = ContinuousClock.now + .seconds(5)
    while captured.values.count < 501, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    LogSystem.flush()
    #expect(captured.values.count == 501)
    #expect(captured.values.last?.message == "\(marker) final")
    #expect(captured.values.allSatisfy { $0.metadata["child_pid"] == .string("42") })
}
