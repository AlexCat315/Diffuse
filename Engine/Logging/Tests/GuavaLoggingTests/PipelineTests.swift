import Foundation
import Testing
import CGuavaLog
@testable import GuavaLogging

private func runtime(_ configure: (inout LoggingConfiguration) -> Void = { _ in }) throws -> LogRuntime {
    let runtime = LogRuntime(runID: "test-run")
    var configuration = LoggingConfiguration { $0.console.enabled = false; $0.storage.enabled = false; $0.filtering.minimum = .trace }
    configure(&configuration); try runtime.configure(configuration, application: "test")
    return runtime
}

@Test func standardLoggerPreservesValueSemanticsAndDynamicModuleFilters() throws {
    let runtime = try runtime { $0.filtering.minimum = .warning; $0.filtering.modules = ["com.test": .debug, "com.test.noisy": .error] }
    var first = runtime.logger("com.test.application"); first[metadataKey: "owner"] = "first"
    var second = first; second[metadataKey: "owner"] = "second"; second.logLevel = .trace
    first.trace("filtered"); second.trace("local override"); first.debug("module default")
    runtime.logger("com.test.noisy.file").warning("filtered noisy")
    runtime.logger("com.testing").info("prefix must match a segment")
    runtime.flush(); let records = runtime.snapshot().records
    #expect(records.map(\.message) == ["local override", "module default"])
    #expect(records[0].metadata["owner"] == .string("second"))
    #expect(records[1].metadata["owner"] == .string("first"))
}

@Test func contextMetadataAndRecursiveRedactionPreserveStructure() async throws {
    let runtime = try runtime()
    var logger = Logger(label: "test") { label in
        var handler = UnifiedLogHandler(label: label, runtime: runtime)
        handler.metadataProvider = .init { ["provided": "dynamic", "precedence": "provider", "trace_id": "provider-trace"] }
        return handler
    }
    logger[metadataKey: "precedence"] = "logger"
    await LogContext.withValues(["trace_id": "trace-1", "precedence": "context"]) {
        await Task.yield()
        logger.info("message", metadata: ["precedence": "event", "nested": .dictionary(["TOKEN": "sensitive", "safe": .array(["a", "b"])])])
    }
    runtime.flush(); let record = try #require(runtime.snapshot().records.first)
    #expect(record.metadata["trace_id"] == .string("provider-trace"))
    #expect(record.metadata["provided"] == .string("dynamic"))
    #expect(record.metadata["precedence"] == .string("event"))
    #expect(record.metadata["nested"] == .object(["TOKEN": .string("[redacted]"), "safe": .array([.string("a"), .string("b")])]))
    #expect(try JSONDecoder().decode(LogRecord.self, from: JSONEncoder().encode(record)) == record)
}

@Test func concurrentWritersHaveOrderedSequencesAndObserverCanLogAgain() async throws {
    let runtime = try runtime { $0.buffering.pendingRecords = 65536; $0.buffering.historyRecords = 2000 }
    let observation = runtime.observe(query: .init(), replay: false) { record in
        if record.message == "nested" { runtime.logger("observer").info("reentrant") }
    }
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<8 { group.addTask { for line in 0..<100 { runtime.logger("worker.\(index)").info("\(line)") } } }
    }
    runtime.logger("test").info("nested"); runtime.flush(); observation.cancel(); runtime.flush()
    let records = runtime.snapshot().records
    #expect(records.count == 802)
    #expect(records.map(\.sequence) == records.map(\.sequence).sorted())
    #expect(records.last?.message == "reentrant")
    #expect(runtime.status.dropped == 0)
}

@Test func partialConfigurationDefaultsAndEnvironmentAreValidated() throws {
    var config = try JSONDecoder().decode(LoggingConfiguration.self, from: Data(#"{"storage":{"filesPerSession":2},"filtering":{"minimum":"warning"}}"#.utf8))
    #expect(config.storage.maximumFileBytes == 8 * 1024 * 1024)
    #expect(config.filtering.minimum == .warning && config.console.enabled)
    let authored = config
    try config.applyEnvironment(["GUAVA_LOG_LEVEL": "debug", "GUAVA_LOG_FILES": "0"])
    #expect(config.filtering.minimum == .debug && !config.storage.enabled)
    #expect(authored.filtering.minimum == .warning && authored.storage.enabled)
    #expect(throws: (any Error).self) { try config.applyEnvironment(["GUAVA_LOG_LEVEL": "wrong"]) }
    #expect(try JSONDecoder().decode(LoggingConfiguration.self, from: JSONEncoder().encode(authored)) == authored)
}

@Test func recordBoundsAndHistoryQueriesAreExplicit() throws {
    let runtime = try runtime { $0.buffering.historyRecords = 2; $0.buffering.messageBytes = 128; $0.buffering.metadataBytes = 128 }
    let logger = runtime.logger("test")
    logger.info("old"); logger.warning("match"); logger.error("\(String(repeating: "你好", count: 1000))", metadata: ["long": "\(String(repeating: "x", count: 1000))"])
    runtime.flush(); let snapshot = runtime.snapshot()
    #expect(snapshot.records.count == 2)
    #expect(snapshot.firstAvailableSequence == 2)
    #expect(snapshot.records.last!.message.utf8.count <= 128)
    #expect(runtime.snapshot(.init { $0.minimum = .warning; $0.text = "match" }).records.count == 1)
}

@Test func boundedQueueReportsLossAndRetainsCriticalEvents() throws {
    let runtime = try runtime { $0.buffering.pendingRecords = 4; $0.storage.flushOnError = false }
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let observation = runtime.observe(query: .init(), replay: false) { record in
        if record.message == "block writer" { entered.signal(); release.wait() }
    }
    runtime.logger("test").info("block writer")
    #expect(entered.wait(timeout: .now() + 2) == .success)
    for _ in 0..<50 { runtime.logger("test").debug("overflow") }
    runtime.logger("test").critical("must retain")
    release.signal(); runtime.flush(); observation.cancel(); runtime.flush()
    #expect(runtime.status.dropped > 0)
    #expect(runtime.snapshot().records.contains { $0.message == "must retain" })
}

@Test func processInstallationIsIdempotentAndNativeRecordsJoinThePipeline() throws {
    let config = LoggingConfiguration { $0.storage.enabled = false; $0.console.enabled = false }
    #expect(try LogSystem.bootstrap(application: "test", configuration: config))
    #expect(try !LogSystem.bootstrap(application: "test", configuration: config))
    guava_log_write(5, "test.native", "native failure", "bridge.c", "init", 42)
    Logger(label: "test.thirdparty").warning("third party")
    Logger(label: "test.provider", metadataProvider: .init { ["provided": "standard"] }).info("provider")
    LogSystem.flush()
    let records = LogSystem.snapshot().records
    let native = try #require(records.first { $0.label == "test.native" })
    #expect(native.level == .error && native.location.file == "bridge.c" && native.location.line == 42)
    #expect(records.contains { $0.label == "test.thirdparty" && $0.message == "third party" })
    #expect(records.contains { $0.label == "test.provider" && $0.metadata["provided"] == .string("standard") })
}
