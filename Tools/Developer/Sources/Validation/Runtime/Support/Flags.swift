internal import Foundation
internal import ToolSupport

/// The slice of `argparse` the ported validators relied on: long options that
/// take one value, spelled `--name VALUE` or `--name=VALUE`.
enum Flags {
  static func matches(_ token: String, _ name: String) -> Bool {
    token == name || token.hasPrefix(name + "=")
  }

  /// Returns the value for `token`, consuming the following token when the
  /// value was not written inline.
  static func value(_ token: String, _ name: String, _ arguments: [String], _ index: inout Int)
    throws -> String
  {
    if token == name {
      index += 1
      guard index < arguments.count else {
        throw ToolError.message("argument \(name): expected one argument")
      }
      return arguments[index]
    }
    return String(token.dropFirst(name.count + 1))
  }
}
