internal import Foundation
private import ToolSupport

/// A JSON value that stays `Sendable`, so DevTools payloads, script results and
/// embedded literals can move between harness layers without `Any` escaping
/// into checked code. `undefined` from the page collapses to `.null`, matching
/// how the reference scripts compare `page.evaluate(...)` against Python `None`.
enum JSON: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSON])
  case object([String: JSON])
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
  init(stringLiteral value: String) { self = .string(value) }
  init(integerLiteral value: Int) { self = .number(Double(value)) }
  init(floatLiteral value: Double) { self = .number(value) }
  init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSON {
  init(any value: Any) {
    switch value {
    case is NSNull:
      self = .null
    case let number as NSNumber:
      if number.isBoolean {
        self = .bool(number.boolValue)
      } else {
        self = .number(number.doubleValue)
      }
    case let text as String:
      self = .string(text)
    case let object as [String: Any]:
      self = .object(object.mapValues(JSON.init(any:)))
    case let items as [Any]:
      self = .array(items.map(JSON.init(any:)))
    default:
      self = .null
    }
  }

  static func parse(_ text: String) throws -> JSON {
    let object = try JSONSerialization.jsonObject(
      with: Data(text.utf8), options: [.fragmentsAllowed])
    return JSON(any: object)
  }

  subscript(key: String) -> JSON? {
    guard case .object(let object) = self else { return nil }
    return object[key]
  }

  var string: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var number: Double? {
    guard case .number(let value) = self else { return nil }
    return value
  }

  var int: Int? {
    guard case .number(let value) = self, value.isFinite else { return nil }
    return Int(value)
  }

  var isInteger: Bool {
    guard case .number(let value) = self, value.isFinite else { return false }
    return value == value.rounded()
  }

  var bool: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  var array: [JSON]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  var object: [String: JSON]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  var count: Int { array?.count ?? object?.count ?? 0 }
  var isNull: Bool { self == .null }

  /// JavaScript truthiness, used to poll `wait_for_function` predicates.
  var isTruthy: Bool {
    switch self {
    case .null: return false
    case .bool(let value): return value
    case .number(let value): return value != 0 && !value.isNaN
    case .string(let value): return !value.isEmpty
    case .array, .object: return true
    }
  }

  /// A JavaScript/JSON literal. Strings keep their Unicode scalars so the
  /// emoji, Arabic, and Devanagari fixtures round-trip through `evaluate`.
  var serialized: String {
    switch self {
    case .null: return "null"
    case .bool(let value): return value ? "true" : "false"
    case .number(let value):
      if value.isFinite, value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
        return String(Int(value))
      }
      return String(value)
    case .string(let value): return JSON.quote(value)
    case .array(let items): return "[" + items.map(\.serialized).joined(separator: ",") + "]"
    case .object(let object):
      let entries = object.keys.sorted().map { JSON.quote($0) + ":" + object[$0]!.serialized }
      return "{" + entries.joined(separator: ",") + "}"
    }
  }

  static func quote(_ value: String) -> String {
    var out = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      default:
        if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }

  var prettyText: String {
    switch self {
    case .null, .bool, .number, .string: return serialized
    default:
      var options: JSONSerialization.WritingOptions = [
        .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
      ]
      options.insert(.fragmentsAllowed)
      guard
        let data = try? JSONSerialization.data(withJSONObject: foundationValue, options: options)
      else {
        return serialized
      }
      return String(decoding: data, as: UTF8.self)
    }
  }

  private var foundationValue: Any {
    switch self {
    case .null: return NSNull()
    case .bool(let value): return value
    case .number(let value): return value
    case .string(let value): return value
    case .array(let items): return items.map(\.foundationValue)
    case .object(let object): return object.mapValues(\.foundationValue)
    }
  }
}
