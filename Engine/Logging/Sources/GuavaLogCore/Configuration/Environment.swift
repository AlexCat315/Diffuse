import Foundation
import Logging

public struct LogLaunch: Codable, Sendable {
    public var configuration: LoggingConfiguration
    public var runID: String
    public var application: String
    public init(configuration: LoggingConfiguration, runID: String, application: String = "Guava") { self.configuration = configuration; self.runID = runID; self.application = application }
}

extension LoggingConfiguration {
    /// Environment overrides are process-local and never mutate authored configuration.
    public mutating func applyEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        if let value = environment["GUAVA_LOG_LEVEL"] {
            guard let level = Logger.Level(rawValue: value.lowercased()) else { throw LoggingError.invalidConfiguration }
            filtering.minimum = level
        }
        if let value = environment["GUAVA_LOG_MODULES"] {
            filtering.modules = try JSONDecoder().decode([String: Logger.Level].self, from: Data(value.utf8))
        }
        if let value = environment["GUAVA_LOG_CONSOLE"] { console.enabled = try flag(value) }
        if let value = environment["GUAVA_LOG_FILES"] { storage.enabled = try flag(value) }
        if let value = environment["GUAVA_LOG_DIRECTORY"] { storage.directory = URL(fileURLWithPath: value) }
        if let value = environment["GUAVA_LOG_FORMAT"] {
            guard let format = Console.Format(rawValue: value) else { throw LoggingError.invalidConfiguration }; console.format = format
        }
        #if os(WASI)
        storage.enabled = false
        #endif
        try validate()
    }
    private func flag(_ value: String) throws -> Bool {
        switch value.lowercased() { case "1", "true", "yes": return true; case "0", "false", "no": return false; default: throw LoggingError.invalidConfiguration }
    }
}
