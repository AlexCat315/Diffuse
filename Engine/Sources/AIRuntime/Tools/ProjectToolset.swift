import CapabilityRuntime
import Foundation

/// Host-owned project operations. Scene mutations continue to use capability
/// drafts; these tools address the script workspace and durable project outputs.
public enum ProjectToolset {
    public typealias Executor = @Sendable (String, Data) async throws -> Data

    private static func object(_ properties: [String: JSONSchema] = [:], required: [String] = []) -> JSONSchema {
        .object(properties: properties, required: required, additionalProperties: false)
    }

    private static let filename = JSONSchema.string(
        description: "One top-level Swift filename, such as Game.swift. No directories.",
        minLength: 7, maxLength: 128, pattern: "^[A-Za-z_][A-Za-z0-9_-]*\\.swift$"
    )

    private static let projectPath = JSONSchema.string(description: "Project-relative file path", minLength: 1, maxLength: 1024)
    public static let tools: [AgentTool] = [
        AgentTool(name: "list_files", description: "List visible workspace files without opening or executing them.", schema: object(), readOnly: true),
        AgentTool(name: "read_file", description: "Read a UTF-8 text/code document, including its unsaved buffer. Read before editing.", schema: object(["path": projectPath], required: ["path"]), readOnly: true),
        AgentTool(name: "write_file", description: "Save a UTF-8 text/code file without executing it. Existing files require the exact expected_text from read_file. Unsaved buffers and external edits are protected.", schema: object(["path": projectPath, "text": .string(minLength: 0, maxLength: 262_144), "expected_text": .string(minLength: 0, maxLength: 262_144)], required: ["path", "text"]), readOnly: false),
        AgentTool(name: "get_media_timeline", description: "Read authored video cuts and export settings.", schema: object(), readOnly: true),
        AgentTool(name: "add_media_clip", description: "Append a project video file to the timeline after inspecting its streams and duration.", schema: object(["path": projectPath], required: ["path"]), readOnly: false),
        AgentTool(name: "trim_media_clip", description: "Set a clip's source in-point and duration in seconds.", schema: object(["index": .integer(minimum: 0, maximum: 255), "start": .number(minimum: 0), "duration": .number(minimum: 0.001)], required: ["index", "start", "duration"]), readOnly: false),
        AgentTool(name: "remove_media_clip", description: "Remove one cut from the timeline; source media is preserved.", schema: object(["index": .integer(minimum: 0, maximum: 255)], required: ["index"]), readOnly: false),
        AgentTool(name: "save_media_timeline", description: "Save authored cuts to .guava/media.json.", schema: object(), readOnly: false),
        AgentTool(name: "export_media", description: "Render the current cuts with FFmpeg to a new MP4 in Exports. Returns the actual output path or error.", schema: object(), readOnly: false),
        AgentTool(name: "get_project_info", description: "Read project, playback, AI availability, script trust and pending review status.", schema: object(), readOnly: true),
        AgentTool(name: "get_scripting_api", description: "Read the supported Swift gameplay API and usage examples before authoring scripts.", schema: object(), readOnly: true),
        AgentTool(name: "get_runtime_state", description: "Inspect current gameplay entity count, unresolved scripts and values reported by ScriptContext.reportState. Use during play to verify actual behavior.", schema: object(), readOnly: true),
        AgentTool(name: "list_scripts", description: "List stable script identifiers, source hashes and editor document status.", schema: object(), readOnly: true),
        AgentTool(name: "read_script", description: "Read a project Swift source and its SHA-256. Read before modifying an existing file.", schema: object(["filename": filename], required: ["filename"]), readOnly: true),
        AgentTool(name: "write_script", description: "Create or update one project Swift source. Does not execute it. Existing files require the expected_sha256 returned by read_script; unsaved editor buffers are protected.", schema: object([
            "filename": filename,
            "source": .string(description: "Complete UTF-8 Swift source defining GameScript: ScriptBehavior.", minLength: 1, maxLength: 262_144),
            "expected_sha256": .string(description: "Required when replacing an existing source; omit for a new file.", minLength: 64, maxLength: 64),
        ], required: ["filename", "source"]), readOnly: false),
        AgentTool(name: "compile_scripts", description: "Compile and load trusted project scripts. Returns per-file success and compiler diagnostics. Project trust must be granted by the human in the Scripts panel.", schema: object(), readOnly: false),
        AgentTool(name: "save_scene", description: "Save the current authored scene to this project's normal scene file after pending scene edits have been reviewed.", schema: object(), readOnly: false),
        AgentTool(name: "export_project", description: "Export this project with the configured Player, checking scripts and executable compatibility. Returns the runnable artifact path or the actual failure.", schema: object(), readOnly: false),
        AgentTool(name: "set_playback_state", description: "Play, pause or stop the current scene. Stop restores authored scene state.", schema: object(["state": .string(allowedValues: ["playing", "paused", "stopped"])], required: ["state"]), readOnly: false),
        AgentTool(name: "get_console_messages", description: "Read recent editor diagnostics to inspect compile, export and runtime failures.", schema: object(["limit": .integer(minimum: 1, maximum: 50)]), readOnly: true),
    ] + UIDiagnosticTools.tools

    public static let responseTool = AgentTool(
        name: "respond", description: "Finish with a useful answer or report. Use for questions and completed project work; use submit_plan for unapplied scene drafts.",
        schema: object(["message": .string(minLength: 1, maxLength: 16_384)], required: ["message"]), readOnly: true
    )

    public static func definition(named name: String) -> AgentTool? {
        (tools + [responseTool]).first { $0.name == name }
    }

    public static func providerDefinitions(format: SessionAPIFormat, allowedNames: Set<String>? = nil) -> [[String: Any]] {
        (tools + [responseTool]).filter { allowedNames?.contains($0.name) ?? true }
            .map { $0.providerDefinition(format: format) }
    }
}
