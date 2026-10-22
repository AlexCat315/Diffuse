import Swift

extension JSON {
    /// Parses one JSON document; nil when it is malformed or nests too deeply.
    public static func parse(_ text: String) -> JSON? {
        var text = text
        return text.withUTF8 { bytes in
            var parser = JSONParser(bytes: bytes)
            guard let value = parser.value(depth: 0) else { return nil }
            parser.skipWhitespace()
            return parser.index == bytes.count ? value : nil
        }
    }
}

private struct JSONParser {
    let bytes: UnsafeBufferPointer<UInt8>
    var index = 0

    mutating func skipWhitespace() {
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x0A || bytes[index] == 0x0D || bytes[index] == 0x09 {
            index += 1
        }
    }

    private mutating func consume(_ literal: StaticString) -> Bool {
        let count = literal.utf8CodeUnitCount
        guard index + count <= bytes.count else { return false }
        for offset in 0..<count where bytes[index + offset] != literal.utf8Start[offset] { return false }
        index += count
        return true
    }

    mutating func value(depth: Int) -> JSON? {
        guard depth < 64 else { return nil }
        skipWhitespace()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "{"): return object(depth: depth)
        case UInt8(ascii: "["): return array(depth: depth)
        case UInt8(ascii: "\""): return string().map(JSON.string)
        case UInt8(ascii: "t"): return consume("true") ? .bool(true) : nil
        case UInt8(ascii: "f"): return consume("false") ? .bool(false) : nil
        case UInt8(ascii: "n"): return consume("null") ? .null : nil
        default: return number()
        }
    }

    private mutating func object(depth: Int) -> JSON? {
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            guard let member = value(depth: depth + 1) else { return nil }
            object[key] = member
            skipWhitespace()
            guard index < bytes.count else { return nil }
            index += 1
            if bytes[index - 1] == UInt8(ascii: "}") { return .object(object) }
            guard bytes[index - 1] == UInt8(ascii: ",") else { return nil }
        }
    }

    private mutating func array(depth: Int) -> JSON? {
        index += 1
        var elements: [JSON] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
        while true {
            guard let element = value(depth: depth + 1) else { return nil }
            elements.append(element)
            skipWhitespace()
            guard index < bytes.count else { return nil }
            index += 1
            if bytes[index - 1] == UInt8(ascii: "]") { return .array(elements) }
            guard bytes[index - 1] == UInt8(ascii: ",") else { return nil }
        }
    }

    private mutating func number() -> JSON? {
        var negative = false
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { negative = true; index += 1 }
        let start = index
        var value: Int64 = 0
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            let digit = Int64(bytes[index] - 0x30)
            // Saturates rather than trapping; a 128-bit multiply needs compiler-rt.
            value = value > (Int64.max - digit) / 10 ? Int64.max : value &* 10 &+ digit
            index += 1
        }
        guard index > start else { return nil }
        // Fractions and exponents are read and dropped.
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
        }
        return .number(negative ? -value : value)
    }

    /// Reads a string starting at its opening quote.
    mutating func string() -> String? {
        index += 1
        let start = index
        while index < bytes.count, bytes[index] != UInt8(ascii: "\""), bytes[index] != UInt8(ascii: "\\") { index += 1 }
        guard index < bytes.count else { return nil }
        if bytes[index] == UInt8(ascii: "\"") {
            index += 1
            return String(utf8: UnsafeBufferPointer(rebasing: bytes[start..<index - 1]))
        }
        var decoded = Array(bytes[start..<index])
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\"") { return String(decoding: decoded, as: UTF8.self) }
            guard byte == UInt8(ascii: "\\") else { decoded.append(byte); continue }
            guard index < bytes.count else { return nil }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): decoded.append(escape)
            case UInt8(ascii: "b"): decoded.append(0x08)
            case UInt8(ascii: "f"): decoded.append(0x0C)
            case UInt8(ascii: "n"): decoded.append(0x0A)
            case UInt8(ascii: "r"): decoded.append(0x0D)
            case UInt8(ascii: "t"): decoded.append(0x09)
            case UInt8(ascii: "u"):
                guard var scalar = hexQuad() else { return nil }
                if scalar >= 0xD800, scalar < 0xDC00, consume("\\u"), let low = hexQuad(), low >= 0xDC00, low < 0xE000 {
                    scalar = 0x10000 + (scalar - 0xD800) << 10 + (low - 0xDC00)
                }
                appendUTF8(Unicode.Scalar(scalar) ?? "\u{FFFD}", to: &decoded)
            default: return nil
            }
        }
        return nil
    }

    private mutating func hexQuad() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt8
            switch byte {
            case 0x30...0x39: digit = byte - 0x30
            case 0x41...0x46: digit = byte - 0x41 + 10
            case 0x61...0x66: digit = byte - 0x61 + 10
            default: return nil
            }
            value = value << 4 | UInt32(digit)
            index += 1
        }
        return value
    }

    private func appendUTF8(_ scalar: Unicode.Scalar, to bytes: inout [UInt8]) {
        for unit in UTF8.encode(scalar)! { bytes.append(unit) }
    }
}
