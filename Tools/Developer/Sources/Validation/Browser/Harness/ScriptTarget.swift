internal import Foundation

/// The shared script surface implemented by the main page and the Inspector
/// frame, so the verification helpers can run against either one exactly like
/// the reference `page`/`frame` objects.
protocol ScriptTarget: AnyObject {
  func evaluate(_ expression: String, argument: JSON) throws -> JSON
  func waitForFunction(_ expression: String, argument: JSON, timeout: Double) throws
  func locator(_ selector: String) -> Locator
}

extension ScriptTarget {
  func evaluate(_ expression: String) throws -> JSON {
    try evaluate(expression, argument: .null)
  }

  func waitForFunction(_ expression: String, timeout: Double = 30) throws {
    try waitForFunction(expression, argument: .null, timeout: timeout)
  }
}
