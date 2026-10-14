import Foundation
import GuavaLogCore
import CGuavaLog

final class LogRuntime: @unchecked Sendable {
    private struct Capture {
        var configuration: LoggingConfiguration
        var identity: LogRecord.Process
        var pending: [LogRecord] = []
        var scheduled = false
        var sequence: UInt64 = 0
        var dropped: UInt64 = 0
        var reportedDrops: UInt64 = 0
        var configured = false
    }
    private struct Subscriber {
        let query: LogQuery
        let receive: @Sendable (LogRecord) -> Void
    }
    private let lock = NSLock()
    private let worker = LogExecutor()
    private var capture: Capture
    private let formatter = LogFormatter()
    private var history = LogHistory(capacity: 512)
    private var subscribers: [UUID: Subscriber] = [:]
    private var written: UInt64 = 0
    private var writeFailures: UInt64 = 0
    #if !os(WASI)
    private var file: LogFile?
    #endif

    init(runID: String = UUID().uuidString) {
        let sanitizer = RecordSanitizer(.init())
        capture = Capture(configuration: .init { $0.storage.enabled = false },
            identity: .init(pid: Int(ProcessInfo.processInfo.processIdentifier), name: sanitizer.text(ProcessInfo.processInfo.processName, bytes: 256), runID: sanitizer.text(runID, bytes: 256)))
    }
    var configuration: LoggingConfiguration { lock.withLock { capture.configuration } }
    var identity: LogRecord.Process { lock.withLock { capture.identity } }
    func minimum(for label: String) -> Logger.Level { lock.withLock { capture.configuration.filtering.level(for: label) } }
    func logger(_ label: String) -> Logger { Logger(label: label) { UnifiedLogHandler(label: $0, runtime: self) } }

    func configure(_ configuration: LoggingConfiguration, application: String, runID: String? = nil) throws {
        try configuration.validate()
        let sanitizer = RecordSanitizer(configuration)
        let application = sanitizer.text(application, bytes: 256)
        let runID = runID.map { sanitizer.text($0, bytes: 256) }
        let unchanged = lock.withLock { capture.configured && capture.configuration == configuration && capture.identity.name == application && (runID == nil || capture.identity.runID == runID) }
        if unchanged { return }
        worker.sync {
            drain()
            #if !os(WASI)
            let hadFile = file != nil
            do { try file?.flush() } catch { storageFailed(error) }; file = nil
            #endif
            let startup = lock.withLock {
                let startup = !capture.configured
                capture.configuration = configuration
                capture.identity = .init(pid: capture.identity.pid, name: application, runID: runID ?? capture.identity.runID)
                capture.configured = true
                if startup {
                    let identity = capture.identity
                    for index in capture.pending.indices { capture.pending[index].process = identity }
                }
                return startup
            }
            if startup { history.identifyStartup(identity) }
            history.resize(configuration.buffering.historyRecords)
            #if !os(WASI)
            if configuration.storage.enabled {
                do {
                    file = try LogFile(root: configuration.storage.directory ?? LogSystem.defaultDirectory, application: application, configuration: configuration.storage)
                    if !hadFile { for record in history.records { try file?.append(formatter.json(record)) } }
                }
                catch { storageFailed(error) }
            }
            #endif
        }
    }

    func submit(label: String, event: LogEvent, metadata: Logger.Metadata) {
        let config = configuration
        var sanitizer = RecordSanitizer(config)
        let message = sanitizer.text(event.message.description, bytes: config.buffering.messageBytes)
        let values = sanitizer.metadata(metadata)
        let source = LogRecord.Location(source: sanitizer.text(event.source, bytes: 512), file: sanitizer.text(event.file, bytes: 1024),
            function: sanitizer.text(event.function, bytes: 1024), line: event.line)
        var fallback = false
        let schedule = lock.withLock { () -> Bool in
            capture.sequence &+= 1
            let record = LogRecord(sequence: capture.sequence, timestamp: Date().timeIntervalSince1970, level: event.level,
                label: sanitizer.text(label, bytes: 256), message: message, metadata: values, location: source, process: capture.identity)
            if capture.pending.count >= config.buffering.pendingRecords {
                capture.dropped &+= 1
                if event.level >= .error {
                    // Preserve the newest high-severity event; its displaced predecessor is counted.
                    capture.pending.removeFirst(); capture.pending.append(record); fallback = true
                }
                return false
            }
            capture.pending.append(record)
            if capture.scheduled { return false }
            capture.scheduled = true; return true
        }
        if fallback { guava_log_console_write(5, "[Guava logging queue saturated] \(message)") }
        if schedule { worker.async { [weak self] in self?.drain() } }
        if event.level >= .error, config.storage.flushOnError { flush() }
    }

    private func drain() {
        let batch = lock.withLock { () -> [LogRecord] in
            let batch = capture.pending; capture.pending = []; return batch
        }
        for record in batch { output(record) }
        let drops = lock.withLock { () -> UInt64 in
            let count = capture.dropped - capture.reportedDrops; capture.reportedDrops = capture.dropped; return count
        }
        if drops > 0 {
            logger("com.guava.logging").warning("Log queue capacity exceeded", metadata: [
                "dropped": "\(drops)", "total_dropped": "\(lock.withLock { capture.dropped })"])
        }
        let pending = lock.withLock {
            let pending = !capture.pending.isEmpty
            if !pending { capture.scheduled = false }
            return pending
        }
        // Yield between bounded batches so snapshots/configuration cannot starve under a log flood.
        if pending { worker.async { [weak self] in self?.drain() } }
    }
    private func output(_ record: LogRecord) {
        let config = configuration
        if config.console.enabled { formatter.console(record, format: config.console.format) }
        #if !os(WASI)
        do { if let file { try file.append(formatter.json(record)) } }
        catch { storageFailed(error) }
        #endif
        if config.buffering.historyRecords > 0 {
            history.append(record)
        }
        written &+= 1
        for subscriber in Array(subscribers.values) where subscriber.query.matches(record) { subscriber.receive(record) }
    }
    private func storageFailed(_ error: any Error) {
        #if !os(WASI)
        file = nil
        #endif
        writeFailures &+= 1
        logger("com.guava.logging").error("Log file output failed", metadata: ["error": "\(error.localizedDescription)"])
        guava_log_console_write(5, "Guava log file unavailable: \(error.localizedDescription); console and history remain active")
    }
    func flush() {
        guard !worker.isCurrent else { return }
        worker.sync {
            drain()
            #if !os(WASI)
            do { try file?.flush() } catch { storageFailed(error) }
            #endif
        }
    }
    func snapshot(_ query: LogQuery = .init()) -> LogSnapshot {
        worker.sync { LogSnapshot(records: history.records.filter(query.matches), dropped: lock.withLock { capture.dropped }, firstAvailableSequence: history.records.first?.sequence) }
    }
    func observe(query: LogQuery, replay: Bool, receive: @escaping @Sendable (LogRecord) -> Void) -> LogObservation {
        let id = UUID()
        worker.sync {
            if replay { for record in history.records where query.matches(record) { receive(record) } }
            subscribers[id] = Subscriber(query: query, receive: receive)
        }
        return LogObservation { [weak self] in self?.worker.sync { self?.subscribers[id] = nil } }
    }
    var status: LoggingStatus {
        worker.sync {
            #if !os(WASI)
            let location = file?.file
            #else
            let location: URL? = nil
            #endif
            return lock.withLock { LoggingStatus(written: written, dropped: capture.dropped, pending: capture.pending.count, fileFailures: writeFailures, file: location) }
        }
    }
}
