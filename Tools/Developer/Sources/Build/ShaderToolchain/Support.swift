internal import Foundation
internal import ToolSupport

/// Version pinned by `bootstrap-slang` and required by `compile`.
let slangVersion = "2026.19"

/// Creates a uniquely named directory, optionally on the same filesystem as a
/// publication target so the final replace is atomic.
func makeTemporaryDirectory(prefix: String, in parent: URL? = nil) throws -> URL {
  let base = parent ?? FileManager.default.temporaryDirectory
  let url = base.appendingPathComponent("\(prefix)\(UUID().uuidString)")
  try Fs.directory(url)
  return url
}

/// `Path.with_suffix('.reflection.json')` for artifact output paths.
func reflectionURL(for output: URL) -> URL {
  output.deletingPathExtension().appendingPathExtension("reflection.json")
}

/// Runs a tool to completion and returns its trimmed combined output, matching
/// the Python helper's `stdout or stderr` behavior.
@discardableResult
func runTool(_ arguments: [String]) throws -> String {
  try Shell.output(arguments)
}

func parseIntegers(_ values: [String], name: String) throws -> [Int] {
  try values.map { value in
    guard let number = Int(value) else {
      throw ToolError.message("Argument \(name): invalid int value: '\(value)'")
    }
    return number
  }
}
