internal import Foundation

/// Path-style glob limited to `*` and `?` within one path component, matching
/// what `Path.glob` was asked for (`*.bundle`, `C*.modulemap`,
/// `C*.build/module.modulemap`). A missing directory yields no matches, as
/// Python's `Path.glob` does.
enum Glob {
  static func paths(in directory: URL, matching pattern: String) -> [URL] {
    var results = [directory]
    for component in pattern.split(separator: "/").map(String.init) {
      var next: [URL] = []
      for base in results {
        if component.contains("*") || component.contains("?") {
          let entries = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
          next += entries.filter { matches($0, component) }.map { base.appendingPathComponent($0) }
        } else {
          let candidate = base.appendingPathComponent(component)
          if FileManager.default.fileExists(atPath: candidate.path) { next.append(candidate) }
        }
      }
      results = next
    }
    return results
  }

  static func matches(_ name: String, _ pattern: String) -> Bool {
    var expression = "^"
    for character in pattern {
      switch character {
      case "*": expression += "[^/]*"
      case "?": expression += "[^/]"
      default: expression += NSRegularExpression.escapedPattern(for: String(character))
      }
    }
    expression += "$"
    return name.range(of: expression, options: [.regularExpression]) != nil
  }
}
