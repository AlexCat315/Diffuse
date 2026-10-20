internal import Foundation
internal import ToolSupport

/// Minimal JSON reader that preserves object member order and numeric literals
/// so reflection documents round-trip exactly like Python's `json` module.
enum JSONParser {
  static func parse(_ text: String) throws -> JSONValue {
    var parser = Reader(bytes: Array(text.utf8))
    let value = try parser.parseValue()
    parser.skipWhitespace()
    guard parser.isAtEnd else { throw ToolError.message("Trailing content after JSON value") }
    return value
  }

  private struct Reader {
    let bytes: [UInt8]
    var index = 0

    var isAtEnd: Bool { index >= bytes.count }

    mutating func skipWhitespace() {
      while index < bytes.count {
        switch bytes[index] {
        case 0x20, 0x09, 0x0A, 0x0D: index += 1
        default: return
        }
      }
    }

    mutating func parseValue() throws -> JSONValue {
      skipWhitespace()
      guard let byte = peek() else { throw ToolError.message("Unexpected end of JSON input") }
      switch byte {
      case 0x7B: return try parseObject()
      case 0x5B: return try parseArray()
      case 0x22: return .string(try parseString())
      case 0x74, 0x66: return try parseLiteral()
      case 0x6E: return try parseLiteral()
      default: return try parseNumber()
      }
    }

    private mutating func parseObject() throws -> JSONValue {
      advance()  // {
      var members: [(String, JSONValue)] = []
      skipWhitespace()
      if peek() == 0x7D {
        advance()
        return .object(members)
      }
      while true {
        skipWhitespace()
        guard peek() == 0x22 else { throw ToolError.message("Expected object key string") }
        let key = try parseString()
        skipWhitespace()
        guard peek() == 0x3A else { throw ToolError.message("Expected ':' after object key") }
        advance()
        let value = try parseValue()
        members.append((key, value))
        skipWhitespace()
        if peek() == 0x2C {
          advance()
          continue
        }
        if peek() == 0x7D {
          advance()
          break
        }
        throw ToolError.message("Expected ',' or '}' in object")
      }
      return .object(members)
    }

    private mutating func parseArray() throws -> JSONValue {
      advance()  // [
      var values: [JSONValue] = []
      skipWhitespace()
      if peek() == 0x5D {
        advance()
        return .array(values)
      }
      while true {
        values.append(try parseValue())
        skipWhitespace()
        if peek() == 0x2C {
          advance()
          continue
        }
        if peek() == 0x5D {
          advance()
          break
        }
        throw ToolError.message("Expected ',' or ']' in array")
      }
      return .array(values)
    }

    private mutating func parseString() throws -> String {
      advance()  // opening quote
      var result = ""
      var buffer: [UInt8] = []
      func flush() {
        if !buffer.isEmpty {
          result += String(decoding: buffer, as: UTF8.self)
          buffer.removeAll()
        }
      }
      while true {
        guard let byte = peek() else { throw ToolError.message("Unterminated JSON string") }
        advance()
        if byte == 0x22 { break }
        if byte == 0x5C {
          flush()
          guard let escape = peek() else { throw ToolError.message("Unterminated JSON escape") }
          advance()
          switch escape {
          case 0x22: result.append("\"")
          case 0x5C: result.append("\\")
          case 0x2F: result.append("/")
          case 0x62: result.append("\u{08}")
          case 0x66: result.append("\u{0C}")
          case 0x6E: result.append("\n")
          case 0x72: result.append("\r")
          case 0x74: result.append("\t")
          case 0x75:
            let scalar = try parseUnicodeEscape()
            result.unicodeScalars.append(scalar)
          default:
            throw ToolError.message("Invalid JSON escape")
          }
        } else {
          buffer.append(byte)
        }
      }
      flush()
      return result
    }

    private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
      let first = try readHex4()
      if first >= 0xD800 && first <= 0xDBFF {
        guard peek() == 0x5C else {
          throw ToolError.message("Unpaired UTF-16 surrogate in JSON string")
        }
        advance()
        guard peek() == 0x75 else {
          throw ToolError.message("Unpaired UTF-16 surrogate in JSON string")
        }
        advance()
        let second = try readHex4()
        guard second >= 0xDC00 && second <= 0xDFFF else {
          throw ToolError.message("Unpaired UTF-16 surrogate in JSON string")
        }
        let value = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
        return Unicode.Scalar(value)!
      }
      return Unicode.Scalar(first)!
    }

    private mutating func readHex4() throws -> UInt32 {
      var value: UInt32 = 0
      for _ in 0..<4 {
        guard let byte = peek() else {
          throw ToolError.message("Truncated \\u escape in JSON string")
        }
        advance()
        let digit: UInt32
        switch byte {
        case 0x30...0x39: digit = UInt32(byte - 0x30)
        case 0x41...0x46: digit = UInt32(byte - 0x41) + 10
        case 0x61...0x66: digit = UInt32(byte - 0x61) + 10
        default: throw ToolError.message("Invalid \\u escape in JSON string")
        }
        value = (value << 4) | digit
      }
      return value
    }

    private mutating func parseLiteral() throws -> JSONValue {
      if matches("true") { return .bool(true) }
      if matches("false") { return .bool(false) }
      if matches("null") { return .null }
      throw ToolError.message("Invalid JSON literal")
    }

    private mutating func matches(_ literal: String) -> Bool {
      let expected = Array(literal.utf8)
      guard index + expected.count <= bytes.count else { return false }
      for offset in 0..<expected.count where bytes[index + offset] != expected[offset] {
        return false
      }
      index += expected.count
      return true
    }

    private mutating func parseNumber() throws -> JSONValue {
      let start = index
      if peek() == 0x2D { advance() }
      while let byte = peek(), (0x30...0x39).contains(byte) { advance() }
      if peek() == 0x2E {
        advance()
        while let byte = peek(), (0x30...0x39).contains(byte) { advance() }
      }
      if let byte = peek(), byte == 0x65 || byte == 0x45 {
        advance()
        if let sign = peek(), sign == 0x2B || sign == 0x2D { advance() }
        while let byte = peek(), (0x30...0x39).contains(byte) { advance() }
      }
      guard index > start else { throw ToolError.message("Invalid JSON number") }
      return .number(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    private func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }
    private mutating func advance() { index += 1 }
  }
}
