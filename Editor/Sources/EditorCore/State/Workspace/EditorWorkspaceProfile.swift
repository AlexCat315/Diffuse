import CapabilityRuntime
import GuavaUIAgent
import Foundation

public enum EditorWorkflowFeature: String, Sendable, Hashable {
    case documents, media, scene, rendering, animation, simulation, gameplay, scripting, gameBuild
}

/// The tools one kind of content offers, shared by the inspector, commands and
/// assistant. Panels are not gated: every panel stays reachable from any content.
public struct EditorWorkspaceProfile: Sendable {
    public let features: Set<EditorWorkflowFeature>

    public static let builtInPanelIDs: Set<String> = [
        "sidebar", "details", "viewport", "hierarchy", "assets", "console",
        "files", "documents", "media", "developer-tools", "animation", "render-pipeline", "terminal",
        "source-control", "tasks",
    ]

    public static func profile(for content: EditorContent) -> Self {
        switch content {
        case .scene:
            Self(features: [.scene, .rendering, .animation, .simulation, .gameplay, .scripting, .gameBuild])
        case .files:
            // Scripts are files, so their tools come along.
            Self(features: [.documents, .scripting])
        case .timeline:
            Self(features: [.media, .documents])
        }
    }

    public var capabilityIDs: Set<String> {
        guard features.contains(.scene) else { return [] }
        var ids: Set<String> = [
            "scene.get_entities", "scene.get_selection", "scene.find_entities", "scene.describe_components", "scene.spawn_entity",
            "scene.delete_entity", "scene.duplicate_entity", "scene.reparent_entity", "scene.set_name",
            "scene.set_transform", "scene.snap_to_ground", "scene.set_light_type", "scene.set_light_intensity",
            "scene.set_light_color", "scene.set_light_range", "scene.set_light_spot_angles",
            "scene.set_light_cast_shadows", "scene.set_camera_pose", "scene.set_camera_fov",
            "scene.set_camera_aspect_ratio", "scene.set_camera_active", "scene.set_mesh_color",
            "scene.set_material", "scene.set_mesh_visibility",
        ]
        if features.contains(.simulation) {
            ids.formUnion(["scene.set_rigid_body_motion_type", "scene.set_rigid_body_mass",
                "scene.set_rigid_body_gravity_scale", "scene.set_rigid_body_allow_sleep", "scene.set_collider_shape",
                "scene.set_collider_box_extents", "scene.set_collider_sphere_radius", "scene.set_collider_capsule",
                "scene.set_collider_material", "scene.set_constraint_enabled"])
        }
        if features.contains(.gameplay) { ids.formUnion(["scene.set_collider_trigger", "scene.set_collider_layer"]) }
        if features.contains(.scripting) { ids.formUnion(["scene.set_script_property", "scene.set_script_bindings"]) }
        if features.contains(.animation) { ids.formUnion(["scene.set_animation_player", "scene.set_audio_source"]) }
        return ids
    }

    public var projectToolNames: Set<String> {
        var names: Set<String> = ["respond", "get_project_info", "save_scene", "get_console_messages",
                                  "vcs_status", "vcs_diff", "vcs_log", "vcs_commit"]
        names.formUnion(UIDiagnosticTools.tools.map(\.name))
        if features.contains(.documents) { names.formUnion(["list_files", "read_file", "write_file"]) }
        if features.contains(.media) { names.formUnion(["get_media_timeline", "add_media_clip", "trim_media_clip", "remove_media_clip", "save_media_timeline", "export_media"]) }
        if !features.contains(.scene) { names.remove("save_scene") }
        if features.contains(.scripting) {
            names.formUnion(["get_scripting_api", "list_scripts", "read_script", "write_script", "compile_scripts"])
        }
        if features.contains(.gameplay) { names.formUnion(["get_runtime_state", "set_playback_state"]) }
        if features.contains(.gameBuild) { names.insert("export_project") }
        return names
    }
}
