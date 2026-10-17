internal import Foundation

/// One error type for every repository tool, so the CLI can print a single
/// actionable line and return a non-zero status without leaking internals.
package enum ToolError: Error, CustomStringConvertible {
  case message(String)
  case command(String, Int32)

  package var description: String {
    switch self {
    case .message(let text): return text
    case .command(let command, let status): return "\(command) exited with status \(status)"
    }
  }
}

package enum Terminal {
  package static func info(_ text: String) { print(text) }

  package static func warning(_ text: String) {
    FileHandle.standardError.write(Data("warning: \(text)\n".utf8))
  }

  package static func error(_ text: String) {
    FileHandle.standardError.write(Data("error: \(text)\n".utf8))
  }

  package static func fail(_ text: String) -> Never {
    error(text)
    exit(1)
  }

  package static func fail(_ error: any Error) -> Never {
    if let tool = error as? ToolError { fail(tool.description) }
    fail(String(describing: error))
  }
}
