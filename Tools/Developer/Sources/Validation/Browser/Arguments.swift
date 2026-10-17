internal import Foundation
private import ToolSupport

/// Minimal `argparse`-shaped option reader shared by every browser operation:
/// long options take a value as `--name value` or `--name=value`, switches are
/// `--name`, and `-h/--help` records the `--help` flag. Unrecognized options
/// fail the way `argparse` does, and positional tokens are reported separately.
struct FlagParser {
  private let arguments: [String]
  private let valued: Set<String>
  private let switches: Set<String>
  private var index = 0

  private(set) var values: [String: String] = [:]
  private(set) var flags: Set<String> = []
  private(set) var positionals: [String] = []

  init(_ arguments: [String], valued: Set<String>, switches: Set<String> = []) {
    self.arguments = arguments
    self.valued = valued
    self.switches = switches
  }

  mutating func parse() throws {
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      if argument == "-h" || argument == "--help" {
        flags.insert("--help")
        continue
      }
      guard argument.hasPrefix("--") else {
        positionals.append(argument)
        continue
      }
      let body = String(argument.dropFirst(2))
      let name: String
      var inline: String?
      if let equals = body.firstIndex(of: "=") {
        name = String(body[..<equals])
        inline = String(body[body.index(after: equals)...])
      } else {
        name = body
      }
      let option = "--" + name
      if switches.contains(option) {
        guard inline == nil else {
          throw ToolError.message("argument \(option): ignored explicit argument '\(inline!)'")
        }
        flags.insert(option)
      } else if valued.contains(option) {
        if let inline {
          values[option] = inline
        } else {
          guard index < arguments.count else {
            throw ToolError.message("argument \(option): expected one argument")
          }
          values[option] = arguments[index]
          index += 1
        }
      } else {
        throw ToolError.message("unrecognized arguments: \(argument)")
      }
    }
  }

  func require(_ option: String) throws -> String {
    guard let value = values[option] else {
      throw ToolError.message("the following arguments are required: \(option)")
    }
    return value
  }
}

/// Makes a possibly relative command-line path absolute against the caller's
/// working directory, matching `pathlib.Path(...).resolve()`.
func absolutePath(_ path: String) -> URL {
  let url = URL(fileURLWithPath: path)
  if (path as NSString).isAbsolutePath { return url.standardizedFileURL }
  return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(path)
    .standardizedFileURL
}
