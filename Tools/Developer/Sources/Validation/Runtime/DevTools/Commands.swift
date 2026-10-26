internal import Foundation
internal import ToolSupport

/// DevTools clients that drive or inspect an already-running application.
/// These are development tools, not validation gates.
package enum DevToolsCommands {
  package static func run(_ arguments: [String]) throws {
    guard let operation = arguments.first else {
      throw ToolError.message(
        "Missing operation; expected one of \(operations.joined(separator: ", "))")
    }
    let flags = Array(arguments.dropFirst())
    switch operation {
    case "query-ui": try QueryUI.run(flags)
    case "input-ui": try InputUI.run(flags)
    case "activate-ui": try ActivateUI.run(flags)
    case "capture-ui": try CaptureUI.run(flags)
    case "resize-window": try ResizeWindow.run(flags)
    case "record-timings": try RecordTimings.run(flags)
    case "session": try DevelopmentSession.run(flags)
    case "-h", "--help": Terminal.info(usage)
    default:
      throw ToolError.message(
        "Unknown DevTools operation '\(operation)'; expected one of \(operations.joined(separator: ", "))"
      )
    }
  }

  static let operations = [
    "query-ui", "input-ui", "activate-ui", "capture-ui", "resize-window", "record-timings", "session",
  ]

  static let usage = """
    guava task devtools -- <operation> [options]

      query-ui PORT --list|TOOL …   Run one read-only AI tool against the live window
      input-ui PORT …               Deliver input events through DevTools
      activate-ui PORT NODE [ACTION] Activate, increment or decrement a node by id
      capture-ui PORT OUTPUT.jpg    Capture the window draw list through the mirror
      resize-window PORT W H        Resize the main window (logical points)
      record-timings PORT OUT.json FRAMES WARMUP
                                    Record presented window frame timings
      session PROJECT mac|android   Verify a running CLI session's DevTools endpoint

    These operations drive or inspect an already-running application; they are
    development tools, not CI gates. Run one with --help for its flags.
    """
}
