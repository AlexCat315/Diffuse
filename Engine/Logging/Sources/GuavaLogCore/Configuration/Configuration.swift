import Foundation
import Logging

public struct LoggingConfiguration: Codable, Sendable, Equatable {
    public enum Installation: String, Codable, Sendable { case process, local }
    public struct Filtering: Codable, Sendable, Equatable {
        public var minimum = Logger.Level.info
        public var modules: [String: Logger.Level] = [:]
        public init() {}
        private enum CodingKeys: CodingKey { case minimum, modules }
        public init(from decoder: any Decoder) throws {
            self.init()
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try values.decodeIfPresent(Logger.Level.self, forKey: .minimum) { minimum = value }
            if let value = try values.decodeIfPresent([String: Logger.Level].self, forKey: .modules) { modules = value }
        }
        package func level(for label: String) -> Logger.Level {
            modules.keys.filter { label == $0 || label.hasPrefix($0 + ".") }
                .max(by: { $0.count < $1.count }).flatMap { modules[$0] } ?? minimum
        }
    }
    public struct Console: Codable, Sendable, Equatable {
        public enum Format: String, Codable, Sendable { case text, json }
        public var enabled = true
        public var format = Format.text
        public init() {}
        private enum CodingKeys: CodingKey { case enabled, format }
        public init(from decoder: any Decoder) throws {
            self.init()
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try values.decodeIfPresent(Bool.self, forKey: .enabled) { enabled = value }
            if let value = try values.decodeIfPresent(Format.self, forKey: .format) { format = value }
        }
    }
    public struct Storage: Codable, Sendable, Equatable {
        public var enabled = true
        public var directory: URL? = nil
        public var maximumFileBytes = 8 * 1024 * 1024
        public var filesPerSession = 3
        public var retainedSessions = 3
        public var flushOnError = true
        public init() {}
        private enum CodingKeys: CodingKey { case enabled, directory, maximumFileBytes, filesPerSession, retainedSessions, flushOnError }
        public init(from decoder: any Decoder) throws {
            self.init()
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try values.decodeIfPresent(Bool.self, forKey: .enabled) { enabled = value }
            if let value = try values.decodeIfPresent(URL.self, forKey: .directory) { directory = value }
            if let value = try values.decodeIfPresent(Int.self, forKey: .maximumFileBytes) { maximumFileBytes = value }
            if let value = try values.decodeIfPresent(Int.self, forKey: .filesPerSession) { filesPerSession = value }
            if let value = try values.decodeIfPresent(Int.self, forKey: .retainedSessions) { retainedSessions = value }
            if let value = try values.decodeIfPresent(Bool.self, forKey: .flushOnError) { flushOnError = value }
        }
    }
    public struct Buffering: Codable, Sendable, Equatable {
        public var pendingRecords = 1024
        public var historyRecords = 512
        public var messageBytes = 16 * 1024
        public var metadataBytes = 8 * 1024
        public init() {}
        private enum CodingKeys: CodingKey { case pendingRecords, historyRecords, messageBytes, metadataBytes }
        public init(from decoder: any Decoder) throws {
            self.init()
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try values.decodeIfPresent(Int.self, forKey: .pendingRecords) { pendingRecords = value }
            if let value = try values.decodeIfPresent(Int.self, forKey: .historyRecords) { historyRecords = value }
            if let value = try values.decodeIfPresent(Int.self, forKey: .messageBytes) { messageBytes = value }
            if let value = try values.decodeIfPresent(Int.self, forKey: .metadataBytes) { metadataBytes = value }
        }
    }
    public struct Redaction: Codable, Sendable, Equatable {
        public var keys: Set<String> = ["password", "passwd", "token", "secret", "authorization", "cookie", "api_key", "apikey", "access_token", "refresh_token"]
        public init() {}
        private enum CodingKeys: CodingKey { case keys }
        public init(from decoder: any Decoder) throws {
            self.init()
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try values.decodeIfPresent(Set<String>.self, forKey: .keys) { keys = value }
        }
    }
    public var filtering = Filtering()
    public var console = Console()
    public var storage = Storage()
    public var buffering = Buffering()
    public var redaction = Redaction()
    public var installation = Installation.process
    public init(_ configure: (inout Self) -> Void = { _ in }) { configure(&self) }

    private enum CodingKeys: CodingKey { case filtering, console, storage, buffering, redaction, installation }
    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        filtering = try values.decodeIfPresent(Filtering.self, forKey: .filtering) ?? filtering
        console = try values.decodeIfPresent(Console.self, forKey: .console) ?? console
        storage = try values.decodeIfPresent(Storage.self, forKey: .storage) ?? storage
        buffering = try values.decodeIfPresent(Buffering.self, forKey: .buffering) ?? buffering
        redaction = try values.decodeIfPresent(Redaction.self, forKey: .redaction) ?? redaction
        installation = try values.decodeIfPresent(Installation.self, forKey: .installation) ?? installation
    }

    public func validate() throws {
        guard (64 * 1024...1024 * 1024 * 1024).contains(storage.maximumFileBytes),
              (1...32).contains(storage.filesPerSession), (1...64).contains(storage.retainedSessions),
              (1...65536).contains(buffering.pendingRecords), (0...65536).contains(buffering.historyRecords),
              (64...32768).contains(buffering.messageBytes), (64...16384).contains(buffering.metadataBytes),
              filtering.modules.keys.allSatisfy({ !$0.isEmpty }),
              !storage.enabled || storage.maximumFileBytes >= 8 * (buffering.messageBytes + buffering.metadataBytes + 4096) else {
            throw LoggingError.invalidConfiguration
        }
        if let directory = storage.directory, !directory.isFileURL { throw LoggingError.invalidConfiguration }
    }
}

public enum LoggingError: Error, LocalizedError {
    case invalidConfiguration
    public var errorDescription: String? { "Invalid logging limits, module filter or storage directory" }
}
