import Foundation
import Logging

/// Adds the GuavaUI DevTools log message types to the wire schema.
public extension DevToolsProtocol {
    enum LogLevel: String, Codable, Sendable {
        case trace, debug, info, notice, warning, error, critical
    }
}

public struct LogEntryPayload: Codable {
    public var level: String
    public var label: String
    public var message: String
    public var metadata: [String: String]?
    public var source: String
    public var file: String
    public var function: String
    public var line: UInt
    /// Seconds since 1970, with millisecond precision.
    public var timestamp: Double
}

/// `LogHandler` that broadcasts every log record to attached DevTools clients.
///
/// Install once at process start by calling
/// `LoggingSystem.bootstrap { label in LogTap(label: label, sink: tap) }`.
/// Multiple `Logger`s share the same sink so message routing is centralised.
public struct LogTap: LogHandler {

    /// Type-erased delivery point so we don't tangle the LogHandler — which
    /// must be `Sendable` and value-typed — with the DevServer reference.
    public final class Sink: @unchecked Sendable {
        public init() {}

        /// Set by `DevTools` after the server starts.
        public var deliver: ((LogEntryPayload) -> Void)?
    }

    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level = .trace

    public let label: String
    private let sink: Sink

    public init(label: String, sink: Sink) {
        self.label = label
        self.sink = sink
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(level: Logger.Level,
                    message: Logger.Message,
                    metadata explicit: Logger.Metadata?,
                    source: String,
                    file: String,
                    function: String,
                    line: UInt) {
        guard let deliver = sink.deliver else { return }
        let merged = explicit.map { metadata.merging($0) { _, new in new } } ?? metadata
        let mapped = merged.mapValues { String(describing: $0) }
        let entry = LogEntryPayload(
            level: Self.levelName(level),
            label: label,
            message: message.description,
            metadata: mapped.isEmpty ? nil : mapped,
            source: source,
            file: file,
            function: function,
            line: line,
            timestamp: Date().timeIntervalSince1970
        )
        deliver(entry)
    }

    private static func levelName(_ level: Logger.Level) -> String {
        switch level {
        case .trace: return "trace"
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .warning: return "warning"
        case .error: return "error"
        case .critical: return "critical"
        }
    }
}

/// Process-wide installer for `LogTap`. `LoggingSystem.bootstrap` may
/// only be called once per process, so callers that want both their own
/// LogHandler and the DevTools tap should bootstrap a `MultiplexLogHandler`
/// themselves and call the regular `LogTap` initializer from there.
public final class LogTapInstaller: @unchecked Sendable {
    private static let shared = LogTapInstaller()
    private let lock = NSLock()
    private var installed = false

    private init() {}

    /// Bootstrap LoggingSystem to fan every record into `sink`.
    /// Returns `true` when this call performed the bootstrap; `false` if
    /// LoggingSystem was already bootstrapped (either by an earlier
    /// DevTools start or by user code).
    @discardableResult
    public static func bootstrapIfNeeded(sink: LogTap.Sink) -> Bool {
        shared.lock.lock(); defer { shared.lock.unlock() }
        if shared.installed { return false }
        LoggingSystem.bootstrap { label in
            LogTap(label: label, sink: sink)
        }
        shared.installed = true
        return true
    }
}
