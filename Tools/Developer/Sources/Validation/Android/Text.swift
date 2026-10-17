internal import Foundation

extension String {
  /// `str.splitlines()` for the ASCII newline cases the harness sees: line
  /// feeds and carriage returns, with no trailing empty line after a final
  /// newline.
  func splitLines() -> [String] {
    var lines: [String] = []
    var current = ""
    var index = startIndex
    while index < endIndex {
      let character = self[index]
      if character == "\n" {
        lines.append(current)
        current = ""
      } else if character == "\r" {
        lines.append(current)
        current = ""
        let next = self.index(after: index)
        if next < endIndex, self[next] == "\n" { index = next }
      } else {
        current.append(character)
      }
      index = self.index(after: index)
    }
    if !current.isEmpty { lines.append(current) }
    return lines
  }
}
