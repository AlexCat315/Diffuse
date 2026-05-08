import Foundation

/// Tool definition for the `execute_edit_plan` tool, used in Messages API requests.
/// Schema is derived from `SceneEditOp` — the canonical set of atomic scene mutations.
public enum EditPlanTool {
    public static func definition() -> [String: Any] {
        [
            "name": "execute_edit_plan",
            "description": "Execute a multi-step scene edit plan. Each step atomically mutates one aspect of the scene.",
            "input_schema": schema(),
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
                    "description": "[r, g, b] linear 0–1 colour for set_light_color.",
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
                "camera_target": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] look-at point for set_camera_pose.",
                ] as [String: Any],
                "camera_up": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] up vector for set_camera_pose. Default [0, 1, 0].",
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
            ] as [String: Any],
        ]
    }
}
