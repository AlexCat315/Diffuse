import Foundation
import Logging

public enum LogValue: Sendable, Equatable, Hashable, Codable {
    case string(String), array([LogValue]), object([String: LogValue])
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([LogValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: LogValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .string(let x): try c.encode(x); case .array(let x): try c.encode(x); case .object(let x): try c.encode(x) }
    }
}

public struct LogRecord: Codable, Sendable, Equatable, Hashable {
    public struct Location: Codable, Sendable, Equatable, Hashable {
        public let source: String
        public let file: String
        public let function: String
        public let line: UInt
        public init(source: String, file: String, function: String, line: UInt) {
            self.source = source; self.file = file; self.function = function; self.line = line
        }
    }
    public struct Process: Codable, Sendable, Equatable, Hashable {
        public let pid: Int
        public let name: String
        public let runID: String
        public init(pid: Int, name: String, runID: String) { self.pid = pid; self.name = name; self.runID = runID }
    }
    public let sequence: UInt64
    public let timestamp: Double
    public let level: Logger.Level
    public let label: String
    public let message: String
    public let metadata: [String: LogValue]
    public let location: Location
    public package(set) var process: Process
    public init(sequence: UInt64, timestamp: Double, level: Logger.Level, label: String, message: String,
                metadata: [String: LogValue], location: Location, process: Process) {
        self.sequence = sequence; self.timestamp = timestamp; self.level = level; self.label = label
        self.message = message; self.metadata = metadata; self.location = location; self.process = process
    }

}

public struct LogQuery: Codable, Sendable, Equatable, Hashable {
    public var minimum = Logger.Level.trace
    public var labels: [String] = []
    public var text = ""
    public var afterSequence: UInt64? = nil
    public init(_ configure: (inout Self) -> Void = { _ in }) { configure(&self) }
    private enum CodingKeys: CodingKey { case minimum, labels, text, afterSequence }
    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        minimum = try values.decodeIfPresent(Logger.Level.self, forKey: .minimum) ?? minimum
        labels = try values.decodeIfPresent([String].self, forKey: .labels) ?? labels
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? text
        afterSequence = try values.decodeIfPresent(UInt64.self, forKey: .afterSequence)
    }
    public func matches(_ record: LogRecord) -> Bool {
        guard record.level >= minimum, afterSequence.map({ record.sequence > $0 }) ?? true,
              labels.isEmpty || labels.contains(where: { record.label == $0 || record.label.hasPrefix($0 + ".") }) else { return false }
        return text.isEmpty || (record.label + " " + record.message + " " + String(describing: record.metadata) + " " + record.location.file + " " + record.location.function + " " + record.process.runID).localizedCaseInsensitiveContains(text)
    }
}

public struct LogSnapshot: Codable, Sendable {
    public let records: [LogRecord]
    public let dropped: UInt64
    public let firstAvailableSequence: UInt64?
    public init(records: [LogRecord], dropped: UInt64, firstAvailableSequence: UInt64?) {
        self.records = records; self.dropped = dropped; self.firstAvailableSequence = firstAvailableSequence
    }
}
