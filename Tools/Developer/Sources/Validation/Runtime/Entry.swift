internal import Foundation
internal import ToolSupport

/// Repository validations that need a built editor or MCP server. The first
/// token selects the operation; the rest are its arguments.
///
/// Replaces `scripts/check-guava-mcp-protocol.py`, `validate-crystal-rush-mcp.py`,
/// `validate-agent-diagnostics.py`, `validate-editor-native-loop.py`,
/// `verify-development-session.mjs`, and the DevTools Swift scripts.
package enum RuntimeValidation {
  package static func run(_ arguments: [String]) throws {
    guard let operation = arguments.first else {
      throw ToolError.message(
        "Missing operation; expected one of \(operations.joined(separator: ", "))")
    }
    let flags = Array(arguments.dropFirst())
    switch operation {
    case "mcp-protocol": try MCPProtocolCheck.run(flags)
    case "crystal-rush": try CrystalRush.run(flags)
    case "agent-diagnostics": try AgentDiagnostics.run(flags)
    case "editor-loop": try EditorNativeLoop.run(flags)
    case "session": try DevelopmentSession.run(flags)
    case "query-ui": try QueryUI.run(flags)
    case "input-ui": try InputUI.run(flags)
    case "capture-ui": try CaptureUI.run(flags)
    case "record-timings": try RecordTimings.run(flags)
    case "-h", "--help": Terminal.info(usage)
    default:
      throw ToolError.message(
        "Unknown validation operation '\(operation)'; expected one of \(operations.joined(separator: ", "))"
      )
    }
  }

  static let operations = [
    "mcp-protocol", "crystal-rush", "agent-diagnostics", "editor-loop", "session",
    "query-ui", "input-ui", "capture-ui", "record-timings",
  ]

  static let usage = """
    guava-dev validate <operation> [options]

      mcp-protocol                  Exercise the built GuavaMCP stdio server's protocol edges
      crystal-rush [options]        Create and validate Crystal Rush through the MCP server
      agent-diagnostics             Drive stdio MCP through the editor's TCP bridge
      editor-loop [options]         Launch the real editor; compile, play, capture, export
      session PROJECT mac|android   Verify a running CLI session's DevTools endpoint
      query-ui PORT --list|TOOL …   Run one read-only AI tool against the live window
      input-ui PORT …               Deliver input events through DevTools
      capture-ui PORT OUTPUT.jpg    Capture the window draw list through the mirror
      record-timings PORT OUT.json FRAMES WARMUP
                                    Record presented window frame timings

    Every operation needs a built editor or MCP server and a running session;
    run one with --help for its flags.
    """
}
