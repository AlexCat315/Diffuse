internal import Foundation
internal import ToolSupport

/// One command-line option. `arity` is 0 for toggles, a positive count for
/// fixed-width values (`nargs=N`), or -1 for a greedy one-or-more list
/// (`nargs='+'`).
struct ArgumentDefinition {
  let name: String
  let arity: Int
  let required: Bool
  let choices: [String]?

  init(name: String, arity: Int, required: Bool = false, choices: [String]? = nil) {
    self.name = name
    self.arity = arity
    self.required = required
    self.choices = choices
  }
}

/// Focused argparse-compatible parser: long options with `--`, optional
/// `--name=value`, fixed or greedy value lists, choice validation, and
/// positional arguments.
enum ArgumentParser {
  struct Parsed {
    let values: [String: [String]]
    let positionals: [String]

    func value(_ name: String) -> String? { values[name]?.last }
    func list(_ name: String) -> [String]? { values[name] }
    func isPresent(_ name: String) -> Bool { values[name] != nil }
  }

  static func parse(
    _ arguments: [String], definitions: [ArgumentDefinition],
    positionalCount: Int
  ) throws -> Parsed {
    let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
    var values: [String: [String]] = [:]
    var positionals: [String] = []
    var index = 0
    while index < arguments.count {
      let token = arguments[index]
      index += 1
      guard token.hasPrefix("--") else {
        positionals.append(token)
        continue
      }
      let (name, inlineValue) = split(token)
      guard let definition = byName[name] else {
        throw ToolError.message("Unrecognized argument: \(token)")
      }
      var collected: [String] = []
      if let inlineValue { collected.append(inlineValue) }
      if definition.arity == 0 {
        if inlineValue != nil { throw ToolError.message("Argument \(name) does not take a value") }
      } else if definition.arity > 0 {
        if collected.isEmpty {
          guard index + definition.arity <= arguments.count else {
            throw ToolError.message("Argument \(name) expects \(definition.arity) value(s)")
          }
          for _ in 0..<definition.arity {
            collected.append(arguments[index])
            index += 1
          }
        } else if definition.arity != 1 {
          throw ToolError.message("Argument \(name) expects \(definition.arity) value(s)")
        }
      } else {
        while index < arguments.count, !arguments[index].hasPrefix("--") {
          collected.append(arguments[index])
          index += 1
        }
        guard !collected.isEmpty else {
          throw ToolError.message("Argument \(name) expects at least one value")
        }
      }
      if let choices = definition.choices {
        for value in collected where !choices.contains(value) {
          throw ToolError.message(
            "Argument \(name): invalid choice '\(value)' (choose from \(choices.joined(separator: ", ")))"
          )
        }
      }
      values[name] = collected
    }
    guard positionals.count == positionalCount else {
      throw ToolError.message(
        "Expected \(positionalCount) positional argument(s), got \(positionals.count)")
    }
    for definition in definitions where definition.required && values[definition.name] == nil {
      throw ToolError.message("Missing required argument: \(definition.name)")
    }
    return Parsed(values: values, positionals: positionals)
  }

  private static func split(_ token: String) -> (String, String?) {
    let body = token.dropFirst(2)
    guard let separator = body.firstIndex(of: "=") else { return ("--" + body, nil) }
    let name = String(body[body.startIndex..<separator])
    let value = String(body[body.index(after: separator)...])
    return ("--" + name, value)
  }
}
