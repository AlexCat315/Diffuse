import Foundation

/// The single AI-facing declaration table for built-in capabilities.
///
/// Intent preconditions and release gates remain on `CapabilityDescriptor`; this
/// table enriches those same registered descriptors with the exact model/MCP
/// contract. There is no provider-specific schema copy.
enum BuiltInCapabilityCatalog {
    struct Spec {
        var title: String
        var description: String
        var schema: JSONSchema
        var access: CapabilityAccess
    }

    static func enrich(_ original: CapabilityDescriptor) -> CapabilityDescriptor {
        guard let spec = specifications[original.verb] else { return original }
        var descriptor = original
        descriptor.title = spec.title
        descriptor.capabilityDescription = spec.description
        descriptor.inputSchema = spec.schema
        descriptor.access = spec.access
        descriptor.isAIExposed = true
        return descriptor
    }

    private static let entity = JSONSchema.string(
        description: "Target entity in 'scene:<number>' format.",
        minLength: 7,
        maxLength: 32,
        pattern: "^scene:[0-9]+$"
    )
    private static let parent = JSONSchema.string(
        description: "Parent entity in 'scene:<number>' format. Omit for scene root.",
        minLength: 7,
        maxLength: 32,
        pattern: "^scene:[0-9]+$"
    )
    private static let vec3 = JSONSchema.array(of: .number(), minimumItems: 3, maximumItems: 3)
    private static let colour3 = JSONSchema.array(
        of: .number(minimum: 0, maximum: 1), minimumItems: 3, maximumItems: 3
    )
    private static let colour4 = JSONSchema.array(
        of: .number(minimum: 0, maximum: 1), minimumItems: 4, maximumItems: 4
    )

    private static func object(_ properties: [String: JSONSchema],
                               required: [String] = []) -> JSONSchema {
        .object(properties: properties, required: required, additionalProperties: false)
    }

    private static func write(_ title: String,
                              _ description: String,
                              _ properties: [String: JSONSchema],
                              required: [String] = ["entity_id"],
                              access: CapabilityAccess = .reversibleWrite) -> Spec {
        Spec(title: title,
             description: description,
             schema: object(properties, required: required),
             access: access)
    }

    private static let scriptValue = JSONSchema.choice([
        .string(), .number(), .boolean(),
        .array(of: .choice([.string(), .number(), .boolean()]), maximumItems: 256),
    ])

    static let specifications: [String: Spec] = [
        "system.search_capabilities": Spec(
            title: "Search capabilities",
            description: "Discover capabilities currently allowed for this project and scene.",
            schema: object([
                "query": .string(description: "What ability is needed."),
                "domain": .string(description: "Optional domain filter such as scene."),
                "access": .string(description: "Optional access filter.",
                                  allowedValues: CapabilityAccess.allCases.map(\.rawValue)),
            ], required: ["query"]),
            access: .read
        ),
        "system.submit_plan": Spec(
            title: "Submit plan",
            description: "Submit ordered validated write draft ids for preview and user confirmation.",
            schema: object([
                "summary": .string(description: "One-line description of the whole plan."),
                "reasoning": .string(description: "Optional short explanation."),
                "draft_ids": .array(of: .string(), minimumItems: 0,
                                    maximumItems: CapabilityDraftLimits.maximumDraftsPerPlan),
            ], required: ["summary", "draft_ids"]),
            access: .read
        ),
        "scene.get_entities": Spec(
            title: "Get scene entities",
            description: "Read the AI-visible entity list for the current scene.",
            schema: object([:]), access: .read
        ),
        "scene.get_selection": Spec(
            title: "Get selection",
            description: "Read the currently selected scene entity.",
            schema: object([:]), access: .read
        ),
        "scene.find_entities": Spec(
            title: "Find entities",
            description: "Search entities by name, kind, component, or proximity.",
            schema: object([
                "name": .string(description: "Case-insensitive name substring."),
                "kind": .string(description: "Exact authored entity kind."),
                "component": .string(description: "Required component tag."),
                "near_position": vec3,
                "near_radius": .number(description: "World-space search radius.", minimum: 0),
                "limit": .integer(description: "Maximum result count.", minimum: 1, maximum: 200),
            ]), access: .read
        ),

        "scene.spawn_entity": write(
            "Spawn entity", "Create a mesh, empty, light, or camera entity.",
            [
                "label": .string(description: "Entity display name."),
                "spawn_position": vec3,
                "spawn_kind": .string(allowedValues: ["mesh", "empty", "light", "camera"]),
                "spawn_parent_id": parent,
                "light_type": .string(allowedValues: ["directional", "point", "spot"]),
                "intensity": .number(minimum: 0),
                "color": colour3,
                "range": .number(minimum: 0),
                "light_cast_shadows": .boolean(),
                "camera_fov_y": .number(minimum: 1, maximum: 179),
            ], required: []
        ),
        "scene.delete_entity": write(
            "Delete entity", "Delete an entity and its authored scene state.",
            ["entity_id": entity], access: .destructiveWrite
        ),
        "scene.duplicate_entity": write(
            "Duplicate entity", "Duplicate an entity, optionally with a local-space offset.",
            ["entity_id": entity, "duplicate_offset": vec3]
        ),
        "scene.reparent_entity": write(
            "Reparent entity", "Move an entity beneath another entity or to the scene root.",
            ["entity_id": entity, "parent_id": parent]
        ),
        "scene.set_name": write(
            "Rename entity", "Set an entity's display name.",
            ["entity_id": entity, "name": .string()], required: ["entity_id", "name"]
        ),
        "scene.set_transform": write(
            "Set transform", "Set selected transform fields without overwriting omitted fields.",
            [
                "entity_id": entity,
                "position": vec3,
                "euler_degrees": vec3,
                "scale": .array(of: .number(minimum: 0.001, maximum: 1_000),
                                minimumItems: 3, maximumItems: 3),
            ]
        ),
        "scene.snap_to_ground": write(
            "Snap to ground", "Move an entity to ground plane y=0.", ["entity_id": entity]
        ),

        "scene.set_light_type": write(
            "Set light type", "Change a light to directional, point, or spot.",
            ["entity_id": entity,
             "light_type": .string(allowedValues: ["directional", "point", "spot"])],
            required: ["entity_id", "light_type"]
        ),
        "scene.set_light_intensity": write(
            "Set light intensity", "Set non-negative light intensity.",
            ["entity_id": entity, "intensity": .number(minimum: 0)],
            required: ["entity_id", "intensity"]
        ),
        "scene.set_light_color": write(
            "Set light colour", "Set linear RGB light colour.",
            ["entity_id": entity, "color": colour3], required: ["entity_id", "color"]
        ),
        "scene.set_light_range": write(
            "Set light range", "Set non-negative light range in metres.",
            ["entity_id": entity, "range": .number(minimum: 0)], required: ["entity_id", "range"]
        ),
        "scene.set_light_spot_angles": write(
            "Set spot angles", "Set the spot light inner and outer cone angles.",
            ["entity_id": entity,
             "spot_inner_angle": .number(minimum: 0, maximum: 180),
             "spot_outer_angle": .number(minimum: 0, maximum: 180)],
            required: ["entity_id"]
        ),
        "scene.set_light_cast_shadows": write(
            "Set light shadows", "Enable or disable shadow casting for a light.",
            ["entity_id": entity, "light_cast_shadows": .boolean()],
            required: ["entity_id", "light_cast_shadows"]
        ),

        "scene.set_camera_pose": write(
            "Set camera pose", "Set camera position and look-at target.",
            ["entity_id": entity, "position": vec3, "camera_target": vec3, "camera_up": vec3],
            required: ["entity_id", "position", "camera_target"]
        ),
        "scene.set_camera_fov": write(
            "Set camera FOV", "Set vertical camera field of view in degrees.",
            ["entity_id": entity, "camera_fov_y": .number(minimum: 1, maximum: 179)],
            required: ["entity_id", "camera_fov_y"]
        ),
        "scene.set_camera_aspect_ratio": write(
            "Set camera aspect ratio", "Set the authored camera width/height ratio.",
            ["entity_id": entity, "camera_aspect_ratio": .number(minimum: 0.01, maximum: 100)],
            required: ["entity_id", "camera_aspect_ratio"]
        ),
        "scene.set_camera_active": write(
            "Set active camera", "Enable or disable this camera as the active render camera.",
            ["entity_id": entity, "camera_is_active": .boolean()],
            required: ["entity_id", "camera_is_active"]
        ),

        "scene.set_mesh_color": write(
            "Set mesh colour", "Set the linear RGB colour tint of a render mesh.",
            ["entity_id": entity, "color": colour3], required: ["entity_id", "color"]
        ),
        "scene.set_material": write(
            "Set PBR material", "Update selected PBR material fields.",
            [
                "entity_id": entity,
                "material_base_color": colour4,
                "material_metallic": .number(minimum: 0, maximum: 1),
                "material_roughness": .number(minimum: 0, maximum: 1),
                "material_emissive": colour3,
            ]
        ),
        "scene.set_mesh_visibility": write(
            "Set mesh visibility", "Show or hide a render mesh.",
            ["entity_id": entity, "is_visible": .boolean()], required: ["entity_id", "is_visible"]
        ),

        "scene.set_rigid_body_motion_type": write(
            "Set rigid body motion", "Set static, dynamic, or kinematic motion.",
            ["entity_id": entity,
             "motion_type": .string(allowedValues: ["static", "dynamic", "kinematic"])],
            required: ["entity_id", "motion_type"]
        ),
        "scene.set_rigid_body_mass": write(
            "Set rigid body mass", "Set positive rigid body mass in kilograms.",
            ["entity_id": entity, "mass": .number(minimum: 0.0001)], required: ["entity_id", "mass"]
        ),
        "scene.set_rigid_body_gravity_scale": write(
            "Set gravity scale", "Set the rigid body's gravity multiplier.",
            ["entity_id": entity, "gravity_scale": .number()],
            required: ["entity_id", "gravity_scale"]
        ),
        "scene.set_rigid_body_allow_sleep": write(
            "Set rigid body sleeping", "Allow or prevent a rigid body from sleeping.",
            ["entity_id": entity, "allow_sleep": .boolean()],
            required: ["entity_id", "allow_sleep"]
        ),
        "scene.set_collider_shape": write(
            "Set collider shape", "Set box, sphere, capsule, mesh, or convex collider shape.",
            ["entity_id": entity,
             "collider_shape": .string(allowedValues: ["box", "sphere", "capsule", "cylinder", "heightField", "mesh", "convex"])],
            required: ["entity_id", "collider_shape"]
        ),
        "scene.set_collider_box_extents": write(
            "Set box collider extents", "Set positive box collider half extents.",
            ["entity_id": entity,
             "half_extents": .array(of: .number(minimum: 0.0001), minimumItems: 3, maximumItems: 3)],
            required: ["entity_id", "half_extents"]
        ),
        "scene.set_collider_sphere_radius": write(
            "Set sphere radius", "Set positive sphere collider radius.",
            ["entity_id": entity, "radius": .number(minimum: 0.0001)],
            required: ["entity_id", "radius"]
        ),
        "scene.set_collider_capsule": write(
            "Set capsule dimensions", "Set positive capsule radius and half-height.",
            ["entity_id": entity,
             "radius": .number(minimum: 0.0001),
             "half_height": .number(minimum: 0.0001)],
            required: ["entity_id"]
        ),
        "scene.set_collider_material": write(
            "Set collider material", "Update collider friction, restitution, or density.",
            ["entity_id": entity,
             "friction": .number(minimum: 0, maximum: 1),
             "restitution": .number(minimum: 0, maximum: 1),
             "density": .number(minimum: 0)]
        ),
        "scene.set_collider_trigger": write(
            "Set collider trigger", "Enable or disable trigger behaviour.",
            ["entity_id": entity, "is_trigger": .boolean()], required: ["entity_id", "is_trigger"]
        ),
        "scene.set_collider_layer": write(
            "Set collider layers", "Set collider layer id and interaction mask.",
            ["entity_id": entity,
             "collider_layer_id": .integer(minimum: 0, maximum: 15),
             "collider_layer_mask": .integer(minimum: 0, maximum: 65_535)]
        ),
        "scene.set_constraint_enabled": write(
            "Set constraint enabled", "Enable or disable a physics constraint.",
            ["entity_id": entity, "is_enabled": .boolean()], required: ["entity_id", "is_enabled"]
        ),

        "scene.set_audio_source": write(
            "Set audio source", "Configure an entity's audio source.",
            ["entity_id": entity,
             "audio_clip": .string(),
             "audio_volume": .number(minimum: 0, maximum: 1),
             "audio_pitch": .number(minimum: 0.01, maximum: 4),
             "audio_loop": .boolean(),
             "audio_play_on_awake": .boolean(),
             "audio_spatial_blend": .number(minimum: 0, maximum: 1)]
        ),
        "scene.set_script_property": write(
            "Set script property", "Set one bounded JSON script parameter value.",
            ["entity_id": entity,
             "script_index": .integer(minimum: 0),
             "script_property_name": .string(),
             "script_property_value": scriptValue],
            required: ["entity_id", "script_property_name", "script_property_value"]
        ),
        "scene.set_script_bindings": write(
            "Set script enabled", "Enable or disable an existing script binding.",
            ["entity_id": entity, "script_index": .integer(minimum: 0), "is_enabled": .boolean()],
            required: ["entity_id", "is_enabled"]
        ),
        "scene.set_animation_player": write(
            "Set animation player", "Configure animation clip playback.",
            ["entity_id": entity,
             "animation_clip": .string(),
             "animation_speed": .number(minimum: 0),
             "animation_loop": .boolean(),
             "animation_is_playing": .boolean()]
        ),
    ]
}
