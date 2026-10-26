import AIRuntime
import Foundation
import CoveLogging

/// Host tool policy for the Editor.
///
/// It is deliberately non-blocking: mutating project-tool calls from the
/// built-in assistant and the MCP bridge are recorded for diagnosis, while the
/// existing gates (workflow scope, project trust, review) keep enforcement.
enum EditorToolAudit {
    static let policy = ToolPolicy(handlers: [recordMutatingProjectToolCalls])

    private static let recordMutatingProjectToolCalls: ToolPolicy.Handler = { call in
        guard let tool = ProjectToolset.definition(named: call.name), !tool.readOnly else {
            return .allow(call)
        }
        LogSystem.logger("com.cove.editor.tool-audit").info(
            "Mutating project tool call",
            metadata: [
                "origin": "\(call.origin == .mcp ? "mcp" : "agent")",
                "tool": "\(call.name)",
                "arguments": "\(EditorToolAudit.argumentKeys(call.arguments))",
                "bytes": "\(call.arguments.count)",
            ]
        )
        return .allow(call)
    }

    /// Key names only: audit records never copy tool payloads (source code,
    /// paths, or credentials the model produced).
    private static func argumentKeys(_ arguments: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: arguments) as? [String: Any],
              !object.isEmpty else { return "-" }
        return object.keys.sorted().joined(separator: ",")
    }
}
