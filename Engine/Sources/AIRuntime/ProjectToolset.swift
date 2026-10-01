import CapabilityRuntime
import Foundation

/// Host-owned project operations. Scene mutations continue to use capability
/// drafts; these tools address the script workspace and durable project outputs.
public enum ProjectToolset {
    public typealias Executor = @Sendable (String, Data) async throws -> Data

    public struct Tool: Sendable {
        public let name: String
        public let description: String
        public let schema: JSONSchema
        public let readOnly: Bool

        public var mcpDefinition: [String: Any] {
            ["name": name, "description": description, "inputSchema": schema.jsonObject(),
             "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false]]
        }
    }

    private static func object(_ properties: [String: JSONSchema] = [:], required: [String] = []) -> JSONSchema {
        .object(properties: properties, required: required, additionalProperties: false)
    }

    private static let filename = JSONSchema.string(
        description: "One top-level Swift filename, such as Game.swift. No directories.",
        minLength: 7, maxLength: 128, pattern: "^[A-Za-z_][A-Za-z0-9_-]*\\.swift$"
    )

    public static let tools: [Tool] = [
        Tool(name: "get_project_info", description: "Read project, playback, AI availability, script trust and pending review status.", schema: object(), readOnly: true),
        Tool(name: "get_scripting_api", description: "Read the supported Swift gameplay API and usage examples before authoring scripts.", schema: object(), readOnly: true),
        Tool(name: "get_runtime_state", description: "Inspect current gameplay entity count, unresolved scripts and values reported by ScriptContext.reportState. Use during play to verify actual behavior.", schema: object(), readOnly: true),
        Tool(name: "list_scripts", description: "List stable script identifiers, source hashes and editor document status.", schema: object(), readOnly: true),
        Tool(name: "read_script", description: "Read a project Swift source and its SHA-256. Read before modifying an existing file.", schema: object(["filename": filename], required: ["filename"]), readOnly: true),
        Tool(name: "write_script", description: "Create or update one project Swift source. Does not execute it. Existing files require the expected_sha256 returned by read_script; unsaved editor buffers are protected.", schema: object([
            "filename": filename,
            "source": .string(description: "Complete UTF-8 Swift source defining GameScript: ScriptBehavior.", minLength: 1, maxLength: 262_144),
            "expected_sha256": .string(description: "Required when replacing an existing source; omit for a new file.", minLength: 64, maxLength: 64),
        ], required: ["filename", "source"]), readOnly: false),
        Tool(name: "compile_scripts", description: "Compile and load trusted project scripts. Returns per-file success and compiler diagnostics. Project trust must be granted by the human in the Scripts panel.", schema: object(), readOnly: false),
        Tool(name: "save_scene", description: "Save the current authored scene to this project's normal scene file after pending scene edits have been reviewed.", schema: object(), readOnly: false),
        Tool(name: "export_project", description: "Export this project with the configured Player, checking scripts and executable compatibility. Returns the runnable artifact path or the actual failure.", schema: object(), readOnly: false),
        Tool(name: "set_playback_state", description: "Play, pause or stop the current scene. Stop restores authored scene state.", schema: object(["state": .string(allowedValues: ["playing", "paused", "stopped"])], required: ["state"]), readOnly: false),
        Tool(name: "get_console_messages", description: "Read recent editor diagnostics to inspect compile, export and runtime failures.", schema: object(["limit": .integer(minimum: 1, maximum: 50)]), readOnly: true),
    ]

    public static let responseTool = Tool(
        name: "respond", description: "Finish with a useful answer or report. Use for questions and completed project work; use submit_plan for unapplied scene drafts.",
        schema: object(["message": .string(minLength: 1, maxLength: 16_384)], required: ["message"]), readOnly: true
    )

    public static func definition(named name: String) -> Tool? {
        (tools + [responseTool]).first { $0.name == name }
    }

    public static func providerDefinitions(format: SessionAPIFormat) -> [[String: Any]] {
        (tools + [responseTool]).map { tool in
            switch format {
            case .anthropic:
                return ["name": tool.name, "description": tool.description, "input_schema": tool.schema.jsonObject()]
            case .openAICompatible:
                return ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": tool.schema.jsonObject()]]
            case .openAIResponses:
                return ["type": "function", "name": tool.name, "description": tool.description, "parameters": tool.schema.jsonObject(), "strict": false]
            }
        }
    }
}
