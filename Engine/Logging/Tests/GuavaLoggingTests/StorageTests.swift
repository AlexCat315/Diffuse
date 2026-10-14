import Foundation
import Testing
@testable import GuavaLogging

@Test func rotationRetentionAndFlushProduceReadableJSONLines() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = LoggingConfiguration {
        $0.console.enabled = false; $0.storage.directory = root
        $0.storage.maximumFileBytes = 65536; $0.storage.filesPerSession = 2; $0.storage.retainedSessions = 2
        $0.buffering.pendingRecords = 65536; $0.buffering.messageBytes = 1024; $0.buffering.metadataBytes = 128
    }
    for _ in 0..<4 {
        let runtime = LogRuntime(); try runtime.configure(config, application: "app")
        for _ in 0..<200 { runtime.logger("test").info("\(String(repeating: "x", count: 1000))") }
        runtime.flush()
        let file = try #require(runtime.status.file)
        let files = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        #expect(files.count == 2)
        for file in files {
            let data = try Data(contentsOf: file); #expect(data.count <= 65536)
            for line in data.split(separator: 10) { _ = try JSONDecoder().decode(LogRecord.self, from: Data(line)) }
        }
    }
    #expect(try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("app"), includingPropertiesForKeys: nil).count == 2)
}

@Test func fileFailureKeepsConsoleHistoryAndStatusAvailable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("not a directory".utf8).write(to: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = LogRuntime()
    try runtime.configure(.init { $0.console.enabled = false; $0.storage.directory = root }, application: "test")
    runtime.logger("test").error("still available"); runtime.flush()
    #expect(runtime.status.fileFailures == 1)
    #expect(runtime.snapshot().records.contains { $0.message == "still available" })
}

@Test func activeSessionsAndUnownedDirectoriesSurviveRetention() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let config = LoggingConfiguration { $0.console.enabled = false; $0.storage.directory = root; $0.storage.retainedSessions = 1 }
    let first = LogRuntime(); try first.configure(config, application: "retention")
    first.logger("test").error("durable without explicit flush")
    let active = try #require(first.status.file)
    let unowned = active.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("session-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: unowned, withIntermediateDirectories: false)
    let second = LogRuntime(); try second.configure(config, application: "retention")
    #expect(FileManager.default.fileExists(atPath: active.path))
    #expect(FileManager.default.fileExists(atPath: unowned.path))
    let line = try #require(Data(contentsOf: active).split(separator: 10).last)
    #expect(try JSONDecoder().decode(LogRecord.self, from: Data(line)).message == "durable without explicit flush")
}
