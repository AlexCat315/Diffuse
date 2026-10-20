internal import Foundation
internal import ToolSupport

/// Order-preserving JSON model. NativeRHI artifacts are serialized with
/// Python's `json.dumps(..., indent=2)`, which keeps dictionary insertion order,
/// so objects are modeled as ordered member lists instead of Swift dictionaries.
enum JSONValue: Sendable {
  case object([(String, JSONValue)])
  case array([JSONValue])
  case string(String)
  case number(String)
  case bool(Bool)
  case null

  static func int(_ value: Int) -> JSONValue { .number(String(value)) }
  static func optionalInt(_ value: Int?) -> JSONValue { value.map { .number(String($0)) } ?? .null }

  var objectMembers: [(String, JSONValue)]? {
    if case .object(let members) = self { return members }
    return nil
  }
  var arrayValues: [JSONValue]? {
    if case .array(let values) = self { return values }
    return nil
  }
  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }
  var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }
  var numberValue: String? {
    if case .number(let value) = self { return value }
    return nil
  }
  var intValue: Int? {
    if case .number(let value) = self { return Int(value) }
    return nil
  }
  var doubleValue: Double? {
    if case .number(let value) = self { return Double(value) }
    return nil
  }

  subscript(key: String) -> JSONValue? {
    guard case .object(let members) = self else { return nil }
    return members.first { $0.0 == key }?.1
  }

  /// Replaces or appends a member while preserving the position of an existing key.
  func setting(_ key: String, to value: JSONValue) -> JSONValue {
    guard case .object(var members) = self else { return .object([(key, value)]) }
    if let index = members.firstIndex(where: { $0.0 == key }) {
      members[index].1 = value
    } else {
      members.append((key, value))
    }
    return .object(members)
  }

  func removingMember(_ key: String) -> JSONValue {
    guard case .object(let members) = self else { return self }
    return .object(members.filter { $0.0 != key })
  }
}

extension JSONValue: Equatable {
  /// Python compares parsed JSON structurally: object key order is irrelevant
  /// and numeric literals compare by value (`1 == 1.0`).
  static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
    switch (lhs, rhs) {
    case (.object(let a), .object(let b)):
      guard a.count == b.count else { return false }
      return a.allSatisfy { member in
        b.first { $0.0 == member.0 }.map { $0.1 == member.1 } ?? false
      }
    case (.array(let a), .array(let b)):
      return a == b
    case (.string(let a), .string(let b)):
      return a == b
    case (.number(let a), .number(let b)):
      return numbersEqual(a, b)
    case (.bool(let a), .bool(let b)):
      return a == b
    case (.null, .null):
      return true
    default:
      return false
    }
  }

  private static func numbersEqual(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    if let x = Int(a), let y = Int(b) { return x == y }
    if let x = Double(a), let y = Double(b) { return x == y }
    return false
  }
}

extension JSONValue {
  /// Matches Python's `json.dumps(value, indent: 2)` byte for byte.
  func prettyPrinted(indent: Int = 2) -> String {
    var output = ""
    write(to: &output, depth: 0, indent: indent)
    return output
  }

  private func write(to output: inout String, depth: Int, indent: Int) {
    let pad = String(repeating: " ", count: depth * indent)
    let childPad = String(repeating: " ", count: (depth + 1) * indent)
    switch self {
    case .object(let members):
      if members.isEmpty {
        output += "{}"
        return
      }
      output += "{\n"
      for (index, member) in members.enumerated() {
        output += childPad + JSONValue.quote(member.0) + ": "
        member.1.write(to: &output, depth: depth + 1, indent: indent)
        output += index == members.count - 1 ? "\n" : ",\n"
      }
      output += pad + "}"
    case .array(let values):
      if values.isEmpty {
        output += "[]"
        return
      }
      output += "[\n"
      for (index, value) in values.enumerated() {
        output += childPad
        value.write(to: &output, depth: depth + 1, indent: indent)
        output += index == values.count - 1 ? "\n" : ",\n"
      }
      output += pad + "]"
    case .string(let value):
      output += JSONValue.quote(value)
    case .number(let raw):
      output += raw
    case .bool(let value):
      output += value ? "true" : "false"
    case .null:
      output += "null"
    }
  }

  private static func quote(_ value: String) -> String {
    var output = "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": output += "\\\""
      case "\\": output += "\\\\"
      case "\n": output += "\\n"
      case "\r": output += "\\r"
      case "\t": output += "\\t"
      case Unicode.Scalar(0x08): output += "\\b"
      case Unicode.Scalar(0x0C): output += "\\f"
      default:
        let code = scalar.value
        if code < 0x20 || code > 0x7E {
          if code > 0xFFFF {
            let supplementary = code - 0x10000
            output += String(format: "\\u%04x", 0xD800 + (supplementary >> 10))
            output += String(format: "\\u%04x", 0xDC00 + (supplementary & 0x3FF))
          } else {
            output += String(format: "\\u%04x", code)
          }
        } else {
          output.unicodeScalars.append(scalar)
        }
      }
    }
    output += "\""
    return output
  }
}
