internal import Foundation
internal import ToolSupport

/// One command-line option. `arity` is 0 for a toggle, 1 for a single value,
/// or -1 for a greedy one-or-more list (`argparse` `nargs='+'`).
struct OptionDefinition {
  let name: String
  let arity: Int
  let required: Bool

  init(_ name: String, arity: Int, required: Bool = false) {
    self.name = name
    self.arity = arity
    self.required = required
  }
}

/// Focused `argparse`-compatible parser for the Android operations: long
/// options with `--`, optional `--name=value`, fixed or greedy value lists, and
/// positional arguments. Unknown options and missing required values fail with
/// the same actionable `ToolError` the rest of the CLI uses.
struct ParsedArguments {
  private let values: [String: [String]]
  let positionals: [String]

  func value(_ name: String) -> String? { values[name]?.last }
  func list(_ name: String) -> [String]? { values[name] }
  func isPresent(_ name: String) -> Bool { values[name] != nil }

  static func parse(_ arguments: [String], options: [OptionDefinition], positionals: Int) throws
    -> ParsedArguments
  {
    let byName = Dictionary(uniqueKeysWithValues: options.map { ($0.name, $0) })
    var values: [String: [String]] = [:]
    var collected: [String] = []
    var index = 0
    while index < arguments.count {
      let token = arguments[index]
      index += 1
      guard token.hasPrefix("--") else {
        collected.append(token)
        continue
      }
      let (name, inline) = split(token)
      guard let option = byName[name] else {
        throw ToolError.message("unrecognized arguments: \(token)")
      }
      var items: [String] = []
      if let inline { items.append(inline) }
      if option.arity == 0 {
        guard inline == nil else {
          throw ToolError.message("argument \(name): ignored explicit value")
        }
      } else if option.arity == 1 {
        if items.isEmpty {
          guard index < arguments.count else {
            throw ToolError.message("argument \(name): expected one value")
          }
          items.append(arguments[index])
          index += 1
        }
      } else {
        while index < arguments.count, !arguments[index].hasPrefix("--") {
          items.append(arguments[index])
          index += 1
        }
        guard !items.isEmpty else {
          throw ToolError.message("argument \(name): expected at least one value")
        }
      }
      values[name] = items
    }
    for option in options where option.required && values[option.name] == nil {
      throw ToolError.message("the following arguments are required: \(option.name)")
    }
    guard collected.count == positionals else {
      let name = positionals == 1 ? "1 positional argument" : "\(positionals) positional arguments"
      throw ToolError.message("expected \(name), got \(collected.count)")
    }
    return ParsedArguments(values: values, positionals: collected)
  }

  private static func split(_ token: String) -> (String, String?) {
    let body = token.dropFirst(2)
    guard let separator = body.firstIndex(of: "=") else { return ("--" + body, nil) }
    return ("--" + body[body.startIndex..<separator], String(body[body.index(after: separator)...]))
  }
}
