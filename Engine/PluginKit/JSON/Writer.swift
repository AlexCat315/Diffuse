import Swift

extension JSON {
    /// Compact JSON text.
    public var serialized: String {
        var writer = ByteWriter()
        write(to: &writer)
        return writer.finish()
    }

    func write(to writer: inout ByteWriter) {
        switch self {
        case .null: writer.append("null")
        case let .bool(value): writer.append(value ? "true" : "false")
        case let .number(value): writer.append(String(value))
        case let .string(value): JSON.write(value, to: &writer)
        case let .raw(text): writer.append(text)
        case let .array(elements):
            writer.append(UInt8(ascii: "["))
            for (index, element) in elements.enumerated() {
                if index > 0 { writer.append(UInt8(ascii: ",")) }
                element.write(to: &writer)
            }
            writer.append(UInt8(ascii: "]"))
        case let .object(object):
            writer.append(UInt8(ascii: "{"))
            for (index, member) in object.members.enumerated() {
                if index > 0 { writer.append(UInt8(ascii: ",")) }
                JSON.write(member.key, to: &writer)
                writer.append(UInt8(ascii: ":"))
                member.value.write(to: &writer)
            }
            writer.append(UInt8(ascii: "}"))
        }
    }

    /// Copies runs that need no escape in bulk.
    static func write(_ string: String, to writer: inout ByteWriter) {
        let hex: StaticString = "0123456789abcdef"
        var string = string
        writer.append(UInt8(ascii: "\""))
        string.withUTF8 { source in
            var run = 0
            for index in 0..<source.count {
                let byte = source[index]
                guard byte < 0x20 || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") else { continue }
                writer.append(UnsafeBufferPointer(rebasing: source[run..<index]))
                run = index + 1
                writer.append(0x5C)
                switch byte {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"): writer.append(byte)
                case 0x0A: writer.append(UInt8(ascii: "n"))
                case 0x0D: writer.append(UInt8(ascii: "r"))
                case 0x09: writer.append(UInt8(ascii: "t"))
                default:
                    writer.append("u00")
                    writer.append(hex.utf8Start[Int(byte >> 4)])
                    writer.append(hex.utf8Start[Int(byte & 0x0F)])
                }
            }
            writer.append(UnsafeBufferPointer(rebasing: source[run...]))
        }
        writer.append(UInt8(ascii: "\""))
    }
}

/// Writes JSON as it goes, without building `JSON` values: for results with
/// thousands of entries, where the value tree costs a guest most of its fuel.
public struct JSONWriter {
    private var writer = ByteWriter()
    private var needsComma = false
    /// Whether anything was written at the current level since the last `begin`.
    public var hasElements: Bool { needsComma }

    public init() {}

    /// Continues an array begun in an earlier fragment of a paged result.
    public init(continuingArray hasElements: Bool) { needsComma = hasElements }

    public mutating func beginObject() { separate(); writer.append(UInt8(ascii: "{")); needsComma = false }
    public mutating func endObject() { writer.append(UInt8(ascii: "}")); needsComma = true }
    public mutating func beginArray() { separate(); writer.append(UInt8(ascii: "[")); needsComma = false }
    public mutating func endArray() { writer.append(UInt8(ascii: "]")); needsComma = true }

    /// The next member's name; its value follows.
    public mutating func key(_ name: StaticString) {
        separate()
        writer.append(UInt8(ascii: "\""))
        writer.append(name)
        writer.append("\":")
        needsComma = false
    }

    public mutating func value(_ string: String) { separate(); JSON.write(string, to: &writer); needsComma = true }
    public mutating func value(_ string: String?) { if let string { value(string) } else { null() } }
    public mutating func value(_ number: Int) { separate(); writer.append(String(number)); needsComma = true }
    public mutating func value(_ flag: Bool) { separate(); writer.append(flag ? "true" : "false"); needsComma = true }
    public mutating func null() { separate(); writer.append("null"); needsComma = true }
    public mutating func value(_ json: JSON) { separate(); json.write(to: &writer); needsComma = true }

    /// The document written so far, ready for `JSON.raw`.
    public mutating func finish() -> String { writer.finish() }

    private mutating func separate() {
        if needsComma { writer.append(UInt8(ascii: ",")) }
    }
}
