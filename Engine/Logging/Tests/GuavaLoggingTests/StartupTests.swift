import Foundation
import Testing
@testable import GuavaLogging

@Test func startupRecordsReceiveTheFinalProcessIdentityBeforeFileReplay() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = LogRuntime(runID: "provisional")
    runtime.logger("startup").info("before bootstrap")
    runtime.flush()
    let config = LoggingConfiguration { $0.console.enabled = false; $0.storage.directory = root }
    try runtime.configure(config, application: "real-app", runID: "cli-run")
    runtime.logger("startup").error("after bootstrap")
    let snapshot = runtime.snapshot()
    #expect(snapshot.records.count == 2)
    #expect(snapshot.records.allSatisfy { $0.process.name == "real-app" && $0.process.runID == "cli-run" })
    let file = try #require(runtime.status.file)
    let records = try Data(contentsOf: file).split(separator: 10).map { try JSONDecoder().decode(LogRecord.self, from: Data($0)) }
    #expect(records == snapshot.records)
    try runtime.configure(config, application: "another-app", runID: "another-run")
    #expect(runtime.snapshot().records.first?.process.runID == "cli-run")
}
