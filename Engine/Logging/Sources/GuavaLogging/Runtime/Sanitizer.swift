import Foundation
import GuavaLogCore

struct RecordSanitizer {
    let configuration: LoggingConfiguration
    var budget: Int
    var nodes = 64
    init(_ configuration: LoggingConfiguration) { self.configuration = configuration; budget = configuration.buffering.metadataBytes }
    func text(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var end = text.startIndex, used = 0
        while end < text.endIndex {
            let next = text.index(after: end), count = text[end..<next].utf8.count
            if used + count > max(0, bytes - 16) { break }
            used += count; end = next
        }
        return String(text[..<end]) + "…[truncated]"
    }
    mutating func metadata(_ values: Logger.Metadata, depth: Int = 0) -> [String: LogValue] {
        var result: [String: LogValue] = [:]
        for key in values.keys.sorted() {
            guard budget > 0, nodes > 0, depth < 8 else { result["_truncated"] = .string("true"); break }
            nodes -= 1
            let name = text(key, bytes: min(256, budget)); budget -= name.utf8.count
            if configuration.redaction.keys.contains(where: { $0.lowercased() == key.lowercased() }) { result[name] = .string("[redacted]") }
            else if let value = values[key] { result[name] = convert(value, depth: depth) }
        }
        return result
    }
    mutating func convert(_ value: Logger.Metadata.Value, depth: Int) -> LogValue {
        guard budget > 0, nodes > 0, depth < 8 else { return .string("[truncated]") }
        switch value {
        case .dictionary(let values): return .object(metadata(values, depth: depth + 1))
        case .array(let values):
            var result: [LogValue] = []
            for value in values { guard budget > 0, nodes > 0 else { result.append(.string("[truncated]")); break }; nodes -= 1; result.append(convert(value, depth: depth + 1)) }
            return .array(result)
        case .string(let string): return scalar(string)
        case .stringConvertible(let value): return scalar(String(describing: value))
        }
    }
    mutating func scalar(_ value: String) -> LogValue {
        let string = text(value, bytes: min(2048, budget)); budget -= string.utf8.count
        return .string(string)
    }
}
