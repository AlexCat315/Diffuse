import Foundation

/// Tool definition for the `execute_edit_plan` tool, used in Messages API requests.
/// Schema is derived from `SceneEditOp` — the canonical set of atomic scene mutations.
public enum EditPlanTool {
    /// Anthropic Messages API format.
    public static func definition() -> [String: Any] {
        [
            "name": "execute_edit_plan",
            "description": "Execute a multi-step scene edit plan. Each step atomically mutates one aspect of the scene.",
            "input_schema": schema(),
        ]
    }

    /// OpenAI / DeepSeek chat-completions format.
    public static func openAIDefinition() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "execute_edit_plan",
                "description": "Execute a multi-step scene edit plan. Each step atomically mutates one aspect of the scene.",
                "parameters": schema(),
            ] as [String: Any],
        ]
    }

    // MARK: - Schema

    private static func schema() -> [String: Any] {
        let ops = SceneEditOp.allCases.map(\.rawValue)
        return [
            "type": "object",
            "required": ["summary", "steps"],
            "properties": [
                "summary": [
                    "type": "string",
                    "description": "One-line description of what the overall plan achieves.",
                ] as [String: Any],
                "reasoning": [
                    "type": "string",
                    "description": "Brief explanation of why these steps satisfy the request. Used for debugging.",
                ] as [String: Any],
                "steps": [
                    "type": "array",
                    "description": "Ordered list of atomic mutation steps to execute.",
                    "items": stepSchema(ops: ops),
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    private static func stepSchema(ops: [String]) -> [String: Any] {
        [
            "type": "object",
            "required": ["op"],
            "properties": [
                "op": [
                    "type": "string", "enum": ops,
                    "description": "The mutation operation to perform.",
                ] as [String: Any],
                "entity_id": [
                    "type": "string",
                    "description": "Target entity in 'scene:<number>' format. Required for all ops except spawn_entity.",
                ] as [String: Any],
                "parent_id": [
                    "type": "string",
                    "description": "New parent entity in 'scene:<number>' format for reparent_entity. Omit to move the entity to the scene root.",
                ] as [String: Any],
                "label": [
                    "type": "string",
                    "description": "Entity display name for spawn_entity.",
                ] as [String: Any],
                "spawn_position": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] world position for spawn_entity. Default [0, 0, 0].",
                ] as [String: Any],
                "position": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] world position in metres for set_transform.",
                ] as [String: Any],
                "euler_degrees": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] XYZ intrinsic Euler rotation in degrees for set_transform.",
                ] as [String: Any],
                "scale": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] scale factors for set_transform.",
                ] as [String: Any],
                "name": [
                    "type": "string",
                    "description": "New entity name for set_name.",
                ] as [String: Any],
                "light_type": [
                    "type": "string", "enum": ["directional", "point", "spot"],
                    "description": "Light type for set_light_type.",
                ] as [String: Any],
                "intensity": [
                    "type": "number",
                    "description": "Light intensity for set_light_intensity.",
                ] as [String: Any],
                "color": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[r, g, b] linear 0–1 colour. Used by set_light_color and set_mesh_color. Common values: red=[1,0,0], green=[0,1,0], blue=[0,0,1], white=[1,1,1], black=[0,0,0], yellow=[1,1,0], orange=[1,0.4,0], purple=[0.5,0,0.5].",
                ] as [String: Any],
                "range": [
                    "type": "number",
                    "description": "Light range in metres for set_light_range.",
                ] as [String: Any],
                "spot_inner_angle": [
                    "type": "number",
                    "description": "Spot cone inner angle in degrees for set_light_spot_angles.",
                ] as [String: Any],
                "spot_outer_angle": [
                    "type": "number",
                    "description": "Spot cone outer angle in degrees for set_light_spot_angles.",
                ] as [String: Any],
                "light_cast_shadows": [
                    "type": "boolean",
                    "description": "Whether the light casts shadows for set_light_cast_shadows.",
                ] as [String: Any],
                "camera_target": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] look-at point for set_camera_pose.",
                ] as [String: Any],
                "camera_up": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] up vector for set_camera_pose. Default [0, 1, 0].",
                ] as [String: Any],
                "camera_fov_y": [
                    "type": "number",
                    "description": "Vertical field-of-view in degrees (1–179) for set_camera_fov. Typical: 30=telephoto, 50=normal, 75=wide.",
                ] as [String: Any],
                "camera_is_active": [
                    "type": "boolean",
                    "description": "Whether this camera is the active render camera for set_camera_active.",
                ] as [String: Any],
                "motion_type": [
                    "type": "string", "enum": ["static", "dynamic", "kinematic"],
                    "description": "Rigid body motion type for set_rigidbody_motion.",
                ] as [String: Any],
                "mass": [
                    "type": "number",
                    "description": "Rigid body mass in kg for set_rigidbody_mass.",
                ] as [String: Any],
                "gravity_scale": [
                    "type": "number",
                    "description": "Gravity multiplier for set_rigidbody_gravity.",
                ] as [String: Any],
                "is_trigger": [
                    "type": "boolean",
                    "description": "Collider trigger flag for set_collider_trigger.",
                ] as [String: Any],
                "is_enabled": [
                    "type": "boolean",
                    "description": "Constraint enabled flag for set_constraint_enabled.",
                ] as [String: Any],
                "allow_sleep": [
                    "type": "boolean",
                    "description": "Whether the rigidbody can sleep when at rest. For set_rigidbody_allow_sleep.",
                ] as [String: Any],
                "collider_shape": [
                    "type": "string", "enum": ["box", "sphere", "capsule", "mesh", "convex"],
                    "description": "Collider shape kind for set_collider_shape.",
                ] as [String: Any],
                "half_extents": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] box half-sizes in metres for set_collider_box_extents.",
                ] as [String: Any],
                "radius": [
                    "type": "number",
                    "description": "Sphere or capsule radius in metres for set_collider_sphere_radius or set_collider_capsule.",
                ] as [String: Any],
                "half_height": [
                    "type": "number",
                    "description": "Capsule half-height in metres for set_collider_capsule.",
                ] as [String: Any],
                "friction": [
                    "type": "number",
                    "description": "Collider surface friction (0–1) for set_collider_material.",
                ] as [String: Any],
                "restitution": [
                    "type": "number",
                    "description": "Collider bounciness (0–1) for set_collider_material.",
                ] as [String: Any],
                "density": [
                    "type": "number",
                    "description": "Collider material density for set_collider_material.",
                ] as [String: Any],
                "audio_clip": [
                    "type": "string",
                    "description": "Audio clip asset name (no extension) for set_audio_source.",
                ] as [String: Any],
                "audio_volume": [
                    "type": "number",
                    "description": "Playback volume 0–1 for set_audio_source.",
                ] as [String: Any],
                "audio_pitch": [
                    "type": "number",
                    "description": "Pitch multiplier (1=normal) for set_audio_source.",
                ] as [String: Any],
                "audio_loop": [
                    "type": "boolean",
                    "description": "Whether the clip loops for set_audio_source.",
                ] as [String: Any],
                "audio_play_on_awake": [
                    "type": "boolean",
                    "description": "Auto-play when the simulation starts for set_audio_source.",
                ] as [String: Any],
                "audio_spatial_blend": [
                    "type": "number",
                    "description": "0=2D, 1=3D positional audio for set_audio_source.",
                ] as [String: Any],
                "script_index": [
                    "type": "integer",
                    "description": "Which script binding to modify (0-based). Defaults to 0 when omitted. For set_script_property.",
                ] as [String: Any],
                "script_property_name": [
                    "type": "string",
                    "description": "The parameter key to set in the script's parametersJSON. For set_script_property.",
                ] as [String: Any],
                "script_property_value": [
                    "description": "The new value for the script parameter (string, number, or boolean). For set_script_property.",
                ] as [String: Any],
                "is_visible": [
                    "type": "boolean",
                    "description": "Whether the mesh is visible. For set_mesh_visibility.",
                ] as [String: Any],
                "animation_clip": [
                    "type": "string",
                    "description": "Animation clip name for set_animation_player. Empty string or omit to use the default clip.",
                ] as [String: Any],
                "animation_speed": [
                    "type": "number",
                    "description": "Playback speed multiplier (1=normal) for set_animation_player.",
                ] as [String: Any],
                "animation_loop": [
                    "type": "boolean",
                    "description": "Whether the animation loops for set_animation_player.",
                ] as [String: Any],
                "animation_is_playing": [
                    "type": "boolean",
                    "description": "Whether animation playback is active for set_animation_player.",
                ] as [String: Any],
            ] as [String: Any],
        ]
    }
}
