internal import Foundation
internal import ToolSupport

/// Ordered JSON value used for every device snapshot, session record and
/// report the harness reads or writes. Object key order is preserved so
/// round-tripped snapshots match the Python `json.dumps` output, and the
/// int/double distinction survives because `--ei` broadcast arguments must be
/// formatted exactly like `str(int)`.
enum JSON: Equatable {
  case object([(String, JSON)])
  case array([JSON])
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case null

  // MARK: Access

  /// Mirrors `dict.get(key, None)`: a missing key, or indexing a non-object,
  /// yields `null` rather than failing.
  subscript(key: String) -> JSON {
    guard case .object(let pairs) = self, let value = pairs.first(where: { $0.0 == key }) else {
      return .null
    }
    return value.1
  }

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  var intValue: Int? {
    switch self {
    case .int(let value): return value
    case .double(let value) where value == value.rounded(): return Int(value)
    default: return nil
    }
  }

  var doubleValue: Double? {
    switch self {
    case .int(let value): return Double(value)
    case .double(let value): return value
    default: return nil
    }
  }

  var arrayValue: [JSON]? {
    if case .array(let value) = self { return value }
    return nil
  }

  var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  /// Whole-number geometry: integral values as written, otherwise rounded.
  var roundedInt: Int { intValue ?? pythonRound(doubleValue ?? 0) }

  /// Python truthiness, so `not s['preedit']` and `if s['editor']` port over.
  var isTruthy: Bool {
    switch self {
    case .null: return false
    case .bool(let value): return value
    case .int(let value): return value != 0
    case .double(let value): return value != 0
    case .string(let value): return !value.isEmpty
    case .array(let value): return !value.isEmpty
    case .object(let value): return !value.isEmpty
    }
  }

  /// Convenience for the many `len(snapshot['nodes'])` and `for n in s['nodes']` uses.
  var elements: [JSON] { arrayValue ?? [] }

  /// Safe list indexing: `snapshot['game']['player'][2]` must not trap.
  func at(_ index: Int) -> JSON {
    guard case .array(let items) = self, index >= 0, index < items.count else { return .null }
    return items[index]
  }

  /// Python numeric `value + offset`, preserving the int/double spelling so
  /// device shell arguments format identically to `str(number)`.
  func plus(_ offset: Double) -> JSON {
    switch self {
    case .int(let value): return .int(value + Int(offset))
    case .double(let value): return .double(value + offset)
    default: return .double(offset)
    }
  }

  /// Returns a copy with `key` replaced, mirroring `d[key] = value`.
  func setting(_ key: String, to value: JSON) -> JSON {
    guard case .object(var pairs) = self else { return self }
    if let index = pairs.firstIndex(where: { $0.0 == key }) {
      pairs[index].1 = value
    } else {
      pairs.append((key, value))
    }
    return .object(pairs)
  }

  // MARK: Equatable

  /// Objects compare by key/value membership, matching Python dict equality
  /// where insertion order is irrelevant; numbers compare numerically across
  /// the int/double spellings.
  static func == (lhs: JSON, rhs: JSON) -> Bool {
    switch (lhs, rhs) {
    case (.null, .null): return true
    case (.bool(let a), .bool(let b)): return a == b
    case (.string(let a), .string(let b)): return a == b
    case (.int(let a), .int(let b)): return a == b
    case (.double(let a), .double(let b)): return a == b
    case (.int(let a), .double(let b)), (.double(let b), .int(let a)): return Double(a) == b
    case (.array(let a), .array(let b)): return a == b
    case (.object(let a), .object(let b)):
      guard a.count == b.count else { return false }
      var lookup: [String: JSON] = [:]
      for (key, value) in a { lookup[key] = value }
      guard lookup.count == a.count else { return false }
      for (key, value) in b where lookup[key] != value { return false }
      return true
    default: return false
    }
  }
}

// MARK: - Parsing

extension JSON {
  static func parse(_ text: String) throws -> JSON {
    var parser = Parser(text)
    let value = try parser.value()
    parser.skipWhitespace()
    guard parser.isAtEnd else { throw ToolError.message("Invalid JSON: trailing content") }
    return value
  }

  private struct Parser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ text: String) { bytes = Array(text.utf8) }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func skipWhitespace() {
      while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func value() throws -> JSON {
      skipWhitespace()
      guard index < bytes.count else {
        throw ToolError.message("Invalid JSON: unexpected end of document")
      }
      switch bytes[index] {
      case UInt8(ascii: "{"): return try object()
      case UInt8(ascii: "["): return try array()
      case UInt8(ascii: "\""): return .string(try string())
      case UInt8(ascii: "t"):
        try literal("true")
        return .bool(true)
      case UInt8(ascii: "f"):
        try literal("false")
        return .bool(false)
      case UInt8(ascii: "n"):
        try literal("null")
        return .null
      default: return try number()
      }
    }

    private mutating func object() throws -> JSON {
      index += 1
      skipWhitespace()
      if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
        index += 1
        return .object([])
      }
      var pairs: [(String, JSON)] = []
      while true {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
          throw ToolError.message("Invalid JSON: expected object key")
        }
        let key = try string()
        skipWhitespace()
        try expect(UInt8(ascii: ":"))
        pairs.append((key, try value()))
        skipWhitespace()
        guard index < bytes.count else {
          throw ToolError.message("Invalid JSON: unterminated object")
        }
        if bytes[index] == UInt8(ascii: ",") {
          index += 1
          continue
        }
        try expect(UInt8(ascii: "}"))
        return .object(pairs)
      }
    }

    private mutating func array() throws -> JSON {
      index += 1
      skipWhitespace()
      if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
        index += 1
        return .array([])
      }
      var items: [JSON] = []
      while true {
        items.append(try value())
        skipWhitespace()
        guard index < bytes.count else {
          throw ToolError.message("Invalid JSON: unterminated array")
        }
        if bytes[index] == UInt8(ascii: ",") {
          index += 1
          continue
        }
        try expect(UInt8(ascii: "]"))
        return .array(items)
      }
    }

    private mutating func string() throws -> String {
      index += 1
      var output: [UInt8] = []
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if byte == UInt8(ascii: "\"") { return String(decoding: output, as: UTF8.self) }
        guard byte == UInt8(ascii: "\\") else {
          output.append(byte)
          continue
        }
        guard index < bytes.count else { break }
        let escape = bytes[index]
        index += 1
        switch escape {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): output.append(escape)
        case UInt8(ascii: "b"): output.append(0x08)
        case UInt8(ascii: "f"): output.append(0x0C)
        case UInt8(ascii: "n"): output.append(0x0A)
        case UInt8(ascii: "r"): output.append(0x0D)
        case UInt8(ascii: "t"): output.append(0x09)
        case UInt8(ascii: "u"):
          output.append(contentsOf: try unicodeEscape())
        default: throw ToolError.message("Invalid JSON: unknown escape")
        }
      }
      throw ToolError.message("Invalid JSON: unterminated string")
    }

    /// Decodes `\uXXXX`, joining UTF-16 surrogate pairs like Python does.
    private mutating func unicodeEscape() throws -> [UInt8] {
      let first = try hexQuad()
      var scalar = UInt32(first)
      if (0xD800...0xDBFF).contains(first), index + 1 < bytes.count,
        bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
      {
        index += 2
        let second = try hexQuad()
        if (0xDC00...0xDFFF).contains(second) {
          scalar = 0x10000 + (UInt32(first - 0xD800) << 10) + UInt32(second - 0xDC00)
        }
      }
      guard let unicode = Unicode.Scalar(scalar) else {
        throw ToolError.message("Invalid JSON: bad unicode escape")
      }
      return Array(String(Character(unicode)).utf8)
    }

    private mutating func hexQuad() throws -> UInt16 {
      guard index + 4 <= bytes.count else {
        throw ToolError.message("Invalid JSON: truncated unicode escape")
      }
      var value: UInt16 = 0
      for _ in 0..<4 {
        let digit = bytes[index]
        index += 1
        let nibble: UInt16
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): nibble = UInt16(digit - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): nibble = UInt16(digit - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): nibble = UInt16(digit - UInt8(ascii: "A") + 10)
        default: throw ToolError.message("Invalid JSON: bad unicode escape")
        }
        value = value << 4 | nibble
      }
      return value
    }

    private mutating func number() throws -> JSON {
      let start = index
      while index < bytes.count, isNumberByte(bytes[index]) { index += 1 }
      guard index > start, let text = String(bytes: bytes[start..<index], encoding: .utf8) else {
        throw ToolError.message("Invalid JSON: expected a value")
      }
      if text.contains(".") || text.contains("e") || text.contains("E") {
        guard let value = Double(text) else {
          throw ToolError.message("Invalid JSON: bad number '\(text)'")
        }
        return .double(value)
      }
      guard let value = Int(text) else {
        throw ToolError.message("Invalid JSON: bad number '\(text)'")
      }
      return .int(value)
    }

    private func isNumberByte(_ byte: UInt8) -> Bool {
      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-")
        || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e")
        || byte == UInt8(ascii: "E")
    }

    private mutating func literal(_ text: String) throws {
      let expected = Array(text.utf8)
      guard index + expected.count <= bytes.count,
        Array(bytes[index..<(index + expected.count)]) == expected
      else {
        throw ToolError.message("Invalid JSON: expected '\(text)'")
      }
      index += expected.count
    }

    private mutating func expect(_ byte: UInt8) throws {
      guard index < bytes.count, bytes[index] == byte else {
        throw ToolError.message("Invalid JSON: expected '\(Character(Unicode.Scalar(byte)))'")
      }
      index += 1
    }
  }
}

// MARK: - Writing

extension JSON: CustomStringConvertible {
  /// `str(value)` for the shell arguments the harness forwards: numbers keep
  /// their int/double spelling, strings are unquoted.
  var description: String {
    switch self {
    case .null: return "null"
    case .bool(let value): return value ? "true" : "false"
    case .int(let value): return String(value)
    case .double(let value): return Self.format(value)
    case .string(let value): return value
    case .array(let items): return items.map(\.description).joined(separator: ", ")
    case .object(let pairs): return pairs.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
    }
  }
}

extension JSON {
  /// `json.dumps(value, ensure_ascii=False, indent=2)`.
  func prettyPrinted() -> String {
    var output = ""
    append(to: &output, indent: 0)
    return output
  }

  private func append(to output: inout String, indent: Int) {
    let padding = String(repeating: " ", count: indent * 2)
    let inner = String(repeating: " ", count: (indent + 1) * 2)
    switch self {
    case .null: output += "null"
    case .bool(let value): output += value ? "true" : "false"
    case .int(let value): output += String(value)
    case .double(let value): output += Self.format(value)
    case .string(let value): output += JSON.quoted(value)
    case .array(let items):
      guard !items.isEmpty else {
        output += "[]"
        return
      }
      output += "[\n"
      for (offset, item) in items.enumerated() {
        output += inner
        item.append(to: &output, indent: indent + 1)
        output += offset == items.count - 1 ? "\n" : ",\n"
      }
      output += padding + "]"
    case .object(let pairs):
      guard !pairs.isEmpty else {
        output += "{}"
        return
      }
      output += "{\n"
      for (offset, pair) in pairs.enumerated() {
        output += inner + JSON.quoted(pair.0) + ": "
        pair.1.append(to: &output, indent: indent + 1)
        output += offset == pairs.count - 1 ? "\n" : ",\n"
      }
      output += padding + "}"
    }
  }

  private static func format(_ value: Double) -> String {
    guard value.isFinite else { return "null" }
    if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) + ".0" }
    return String(value)
  }

  /// Python's `json` string escaping with `ensure_ascii=False`.
  private static func quoted(_ value: String) -> String {
    var output = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      case "\u{08}": output += "\\b"
      case "\u{0C}": output += "\\f"
      default:
        if scalar.value < 0x20 {
          output += String(format: "\\u%04x", scalar.value)
        } else {
          output.unicodeScalars.append(scalar)
        }
      }
    }
    return output + "\""
  }
}
