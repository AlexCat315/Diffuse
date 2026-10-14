import Foundation
import GuavaLogCore
import CGuavaLog

struct LogFormatter {
    private let encoder: JSONEncoder = {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return value
    }()
    private let clock: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }()
    func json(_ record: LogRecord) throws -> Data { var data = try encoder.encode(record); data.append(10); return data }
    func text(_ record: LogRecord) -> String {
        let metadata = record.metadata.isEmpty ? "" : " " + String(decoding: (try? encoder.encode(record.metadata)) ?? Data(), as: UTF8.self)
        return "\(clock.string(from: Date(timeIntervalSince1970: record.timestamp))) \(record.level.rawValue.uppercased()) [\(record.label)] \(record.message)\(metadata)"
    }
    func console(_ record: LogRecord, format: LoggingConfiguration.Console.Format) {
        // The CLI already echoed child process output to its original stdout/stderr.
        if record.location.source == "process.stdout" || record.location.source == "process.stderr" { return }
        let text = format == .json ? String(decoding: (try? json(record)) ?? Data(), as: UTF8.self).trimmingCharacters(in: .newlines) : text(record)
        guava_log_console_write(Int32(Logger.Level.allCases.firstIndex(of: record.level) ?? 2), text)
    }
}
