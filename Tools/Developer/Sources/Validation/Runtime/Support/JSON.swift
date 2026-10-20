internal import Foundation
internal import ToolSupport

/// Accessors and encoders for the loosely typed JSON the MCP and DevTools
/// protocols exchange. Every accessor fails with one actionable message
/// instead of a failed cast.
enum JSON {
  // MARK: Parsing

  static func parse(_ data: Data) throws -> Any {
    guard !data.isEmpty else { throw ToolError.message("Expected JSON, received empty input") }
    do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch {
      throw ToolError.message(
        "Malformed JSON: \(String(decoding: data.prefix(512), as: UTF8.self))")
    }
  }

  static func parseObject(_ data: Data) throws -> [String: Any] {
    guard let object = (try? parse(data)) as? [String: Any] else {
      throw ToolError.message(
        "Expected a JSON object, received \(String(decoding: data.prefix(512), as: UTF8.self))")
    }
    return object
  }

  // MARK: Optional accessors

  static func dict(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
  static func list(_ value: Any?) -> [Any]? { value as? [Any] }
  static func objects(_ value: Any?) -> [[String: Any]]? {
    list(value)?.compactMap { $0 as? [String: Any] }
  }
  static func strings(_ value: Any?) -> [String]? { list(value)?.compactMap { $0 as? String } }
  static func string(_ value: Any?) -> String? { value as? String }

  static func int(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, !number.isBoolean else {
      return nil
    }
    return number.intValue
  }

  static func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, !number.isBoolean else {
      return nil
    }
    return number.doubleValue
  }

  static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, number.isBoolean else {
      return nil
    }
    return number.boolValue
  }

  // MARK: Required accessors

  static func object(_ value: Any?, _ what: @autoclosure () -> String) throws -> [String: Any] {
    guard let object = value as? [String: Any] else {
      throw ToolError.message("Expected a JSON object for \(what())")
    }
    return object
  }

  static func array(_ value: Any?, _ what: @autoclosure () -> String) throws -> [Any] {
    guard let array = value as? [Any] else {
      throw ToolError.message("Expected a JSON array for \(what())")
    }
    return array
  }

  static func objects(_ value: Any?, _ what: @autoclosure () -> String) throws -> [[String: Any]] {
    try array(value, what()).compactMap { $0 as? [String: Any] }
  }

  static func string(_ value: Any?, _ what: @autoclosure () -> String) throws -> String {
    guard let text = value as? String else {
      throw ToolError.message("Expected a string for \(what())")
    }
    return text
  }

  static func int(_ value: Any?, _ what: @autoclosure () -> String) throws -> Int {
    guard let number = int(value) else {
      throw ToolError.message("Expected an integer for \(what())")
    }
    return number
  }

  static func boolean(_ value: Any?, _ what: @autoclosure () -> String) throws -> Bool {
    guard let flag = boolean(value) else {
      throw ToolError.message("Expected a boolean for \(what())")
    }
    return flag
  }

  // MARK: Encoding

  static func data(
    _ value: Any, pretty: Bool = false, sortedKeys: Bool = true, fragments: Bool = false
  ) throws -> Data {
    var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes]
    if pretty { options.insert(.prettyPrinted) }
    if sortedKeys { options.insert(.sortedKeys) }
    if fragments { options.insert(.fragmentsAllowed) }
    do { return try JSONSerialization.data(withJSONObject: value, options: options) } catch {
      throw ToolError.message("Cannot encode JSON: \(error.localizedDescription)")
    }
  }

  /// Compact, deterministic rendering used where the Python originals printed
  /// a dictionary or threw it into an assertion message.
  static func text(_ value: Any) -> String {
    guard let data = try? data(value, fragments: true) else { return String(describing: value) }
    return String(decoding: data, as: UTF8.self)
  }

  static func pretty(_ value: Any) -> String {
    guard let data = try? data(value, pretty: true, fragments: true) else {
      return String(describing: value)
    }
    return String(decoding: data, as: UTF8.self)
  }

  static func write(_ value: Any, to url: URL, pretty: Bool = true) throws {
    try Fs.write(try data(value, pretty: pretty), to: url)
  }

  /// `json.dumps` without the trailing newline, for files written directly.
  static func compact(_ value: Any) throws -> String {
    String(decoding: try data(value), as: UTF8.self)
  }
}
