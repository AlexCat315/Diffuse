import CapabilityRuntime
import Foundation

public enum EditorAuthoringDomain: String, Codable, Sendable {
    case game
    case creation

    public var title: String { self == .game ? "Game Development" : "3D Creation" }
}

/// How the user works, independent of the production domain and dock layout.
public enum EditorInteractionMode: String, Codable, Sendable, CaseIterable {
    case manual
    case agent

    public var title: String { self == .manual ? "Manual Editing" : "Agent Workbench" }
}

public enum EditorWorkflowFeature: String, Sendable, Hashable {
    case scene, rendering, animation, simulation, gameplay, scripting, gameBuild
}

/// Functional definition shared by the shell, inspector and assistant. A
/// layout may arrange these tools, but cannot introduce another domain's tools.
public struct EditorWorkspaceProfile: Sendable {
    public let domain: EditorAuthoringDomain
    public let features: Set<EditorWorkflowFeature>
    public let panelIDs: Set<String>

    public static let builtInPanelIDs: Set<String> = [
        "viewport", "hierarchy", "inspector", "assets", "console", "intent-input",
        "confirmation-host", "scripts", "developer-tools", "animation", "render-pipeline",
    ]

    public static func profile(for mode: EditorWorkspaceMode) -> Self {
        let shared: Set<String> = ["viewport", "hierarchy", "inspector", "assets", "console",
                                   "intent-input", "confirmation-host", "render-pipeline"]
        switch mode {
        case .level, .scripting:
            return Self(domain: .game,
                        features: [.scene, .rendering, .animation, .simulation, .gameplay, .scripting, .gameBuild],
                        panelIDs: shared.union(["scripts", "developer-tools", "animation"]))
        case .modeling:
            return Self(domain: .creation, features: [.scene, .rendering], panelIDs: shared)
        case .animation:
            return Self(domain: .creation, features: [.scene, .rendering, .animation, .simulation],
                        panelIDs: shared.union(["animation"]))
        }
    }

    public func allowsPanel(_ id: String) -> Bool {
        // Custom plugin panels keep their own registration and authorization.
        !Self.builtInPanelIDs.contains(id) || panelIDs.contains(id)
    }

    public var capabilityIDs: Set<String> {
        var ids: Set<String> = [
            "scene.get_entities", "scene.get_selection", "scene.find_entities", "scene.spawn_entity",
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
        var names: Set<String> = ["respond", "get_project_info", "save_scene", "get_console_messages"]
        if features.contains(.scripting) {
            names.formUnion(["get_scripting_api", "list_scripts", "read_script", "write_script", "compile_scripts"])
        }
        if features.contains(.gameplay) { names.formUnion(["get_runtime_state", "set_playback_state"]) }
        if features.contains(.gameBuild) { names.insert("export_project") }
        return names
    }

    public func allowsInspectorSection(_ id: String) -> Bool {
        switch id {
        case "scripts": return features.contains(.scripting)
        case "character-controller", "vehicle", "vehicle-controller": return features.contains(.gameplay)
        case "physics-settings", "rigid-body", "collider", "constraint", "destructible", "soft-body",
             "cloth", "soft-body-mesh", "ragdoll": return features.contains(.simulation)
        case "animation-player", "animation-graph-player", "audio-source", "audio-listener":
            return features.contains(.animation)
        default: return true
        }
    }
}

extension EditorWorkspaceMode {
    public var profile: EditorWorkspaceProfile { .profile(for: self) }
}
