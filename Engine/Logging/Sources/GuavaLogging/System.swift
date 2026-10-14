import Foundation
import GuavaLogCore
import CGuavaLog

public struct LoggingStatus: Codable, Sendable {
    public let written: UInt64
    public let dropped: UInt64
    public let pending: Int
    public let fileFailures: UInt64
    public let file: URL?
}

/// Standard swift-log producers, one process backend, independent subscribers.
public enum LogSystem {
    private static let runtime = LogRuntime(runID: ProcessInfo.processInfo.environment["GUAVA_LOG_RUN_ID"] ?? UUID().uuidString)
    private static let installation = Installation()
    private final class Installation: @unchecked Sendable {
        let lock = NSLock()
        var installed = false
    }
    @discardableResult
    public static func bootstrap(application: String = ProcessInfo.processInfo.processName,
                                 configuration: LoggingConfiguration = .init(), runID: String? = nil) throws -> Bool {
        try runtime.configure(configuration, application: application, runID: runID)
        return installation.lock.withLock {
            guava_log_set_handler(nativeLog, flushNativeLogs)
            guard configuration.installation == .process, !installation.installed else { return false }
            LoggingSystem.bootstrap { UnifiedLogHandler(label: $0, runtime: runtime) }
            installation.installed = true; return true
        }
    }
    public static func logger(_ label: String) -> Logger { runtime.logger(label) }
    public static func flush() { runtime.flush() }
    public static var status: LoggingStatus { runtime.status }
    public static var launch: LogLaunch { .init(configuration: runtime.configuration, runID: runtime.identity.runID, application: runtime.identity.name) }
    public static func snapshot(_ query: LogQuery = .init()) -> LogSnapshot { runtime.snapshot(query) }
    public static func observe(query: LogQuery = .init(), replay: Bool = true,
                               receive: @escaping @Sendable (LogRecord) -> Void) -> LogObservation {
        runtime.observe(query: query, replay: replay, receive: receive)
    }
    public static var defaultDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        #if os(Windows)
        return URL(fileURLWithPath: env["LOCALAPPDATA"] ?? FileManager.default.homeDirectoryForCurrentUser.path).appendingPathComponent("Guava/Logs")
        #elseif os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Guava")
        #elseif os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("Guava/Logs")
        #else
        return (env["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")).appendingPathComponent("guava/logs")
        #endif
    }
}

private func nativeLog(_ level: Int32, _ label: UnsafePointer<CChar>?, _ message: UnsafePointer<CChar>?,
                       _ file: UnsafePointer<CChar>?, _ function: UnsafePointer<CChar>?, _ line: UInt32) {
    let severity = Logger.Level.allCases.indices.contains(Int(level)) ? Logger.Level.allCases[Int(level)] : .info
    LogSystem.logger(label.map(String.init(cString:)) ?? "com.guava.native").log(level: severity,
        "\(message.map(String.init(cString:)) ?? "")", metadata: ["origin": "native"], source: "native",
        file: file.map(String.init(cString:)) ?? "", function: function.map(String.init(cString:)) ?? "", line: UInt(line))
}

private func flushNativeLogs() { LogSystem.flush() }
