internal import Foundation
internal import ToolSupport

/// Assertion helpers so a failed check reads like the Python `assert …` it was
/// ported from while still surfacing through `ToolError`.
enum Check {
  static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw ToolError.message(message()) }
  }

  /// `assert a == b, object` — the object is the failure message, as in the
  /// MCP validations.
  static func equal<T: Equatable>(_ actual: T, _ expected: T, _ context: @autoclosure () -> String)
    throws
  {
    guard actual == expected else {
      throw ToolError.message("Expected \(expected), got \(actual): \(context())")
    }
  }

  static func contains(_ text: String, _ needle: String, _ context: @autoclosure () -> String)
    throws
  {
    guard text.contains(needle) else {
      throw ToolError.message("Expected \(JSON.text(needle)) in \(context())")
    }
  }
}
