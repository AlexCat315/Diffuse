import Foundation

/// What the center of the window shows. The panels around it, the inspector's
/// sections, the commands and the assistant's tools follow it.
public enum EditorContent: String, Codable, Sendable, Hashable, CaseIterable {
    case scene
    case files
    case timeline

    public var title: String {
        switch self {
        case .scene: "Scene"
        case .files: "Code"
        case .timeline: "Timeline"
        }
    }

    public var profile: EditorWorkspaceProfile { .profile(for: self) }
}

extension EditorContent {
    /// The content a project tool works on, so the agent view can show it.
    public static func touched(byTool name: String) -> EditorContent? {
        switch name {
        case "get_media_timeline", "add_media_clip", "trim_media_clip", "remove_media_clip",
             "save_media_timeline", "export_media":
            .timeline
        case "list_files", "read_file", "write_file", "get_scripting_api", "list_scripts",
             "read_script", "write_script", "compile_scripts":
            .files
        case "save_scene", "get_runtime_state", "set_playback_state", "export_project":
            .scene
        default:
            nil
        }
    }
}
