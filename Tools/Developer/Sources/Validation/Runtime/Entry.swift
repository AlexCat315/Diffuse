internal import Foundation
internal import ToolSupport

/// Repository validations that need a built editor or MCP server. The first
/// token selects the operation; the rest are its arguments.
///
/// Replaces `scripts/check-diffuse-mcp-protocol.py`, `validate-crystal-rush-mcp.py`,
/// `validate-agent-diagnostics.py`, and `validate-editor-native-loop.py`.
/// DevTools clients live under `cove-dev devtools`, not here.
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
    case "-h", "--help": Terminal.info(usage)
    default:
      throw ToolError.message(
        "Unknown validation operation '\(operation)'; expected one of \(operations.joined(separator: ", "))"
      )
    }
  }

  static let operations = [
    "mcp-protocol", "crystal-rush", "agent-diagnostics", "editor-loop",
  ]

  static let usage = """
    cove-dev validate <operation> [options]

      mcp-protocol                  Exercise the built DiffuseMCP stdio server's protocol edges
      crystal-rush [options]        Create and validate Crystal Rush through the MCP server
      agent-diagnostics             Drive stdio MCP through the editor's TCP bridge
      editor-loop [options]         Launch the real editor; compile, play, capture, export

    Every operation needs a built editor or MCP server; run one with --help for
    its flags. DevTools clients live under `cove-dev devtools`.
    """
}
