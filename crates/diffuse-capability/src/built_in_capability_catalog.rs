//! `BuiltInCapabilityCatalog` — the single AI-facing declaration table for
//! built-in capabilities.
//!
//! Intent preconditions and release gates stay on `CapabilityDescriptor`; this
//! table enriches those registered descriptors with the exact model/MCP contract.

use std::collections::BTreeMap;

use crate::capability_contract::CapabilityAccess;
use crate::capability_descriptor::CapabilityDescriptor;
use crate::capsule_schema::{
    JsonSchema, array, boolean, choice, integer, number, object, string_enum, string_pattern,
};

pub struct Spec {
    pub title: String,
    pub description: String,
    pub schema: JsonSchema,
    pub access: CapabilityAccess,
}

pub enum BuiltInCapabilityCatalog {}

impl BuiltInCapabilityCatalog {
    pub fn enrich(original: &CapabilityDescriptor) -> CapabilityDescriptor {
        let specifications = Self::specifications();
        let Some(spec) = specifications.get(&original.verb) else {
            return original.clone();
        };
        let mut descriptor = original.clone();
        descriptor.title = spec.title.clone();
        descriptor.capability_description = spec.description.clone();
        descriptor.input_schema = spec.schema.clone();
        descriptor.access = spec.access;
        descriptor.is_ai_exposed = true;
        descriptor
    }

    fn entity() -> JsonSchema {
        string_pattern(
            Some("Target entity in 'scene:<number>' format."),
            Some(7),
            Some(32),
            Some("^scene:[0-9]+$"),
        )
    }

    fn parent() -> JsonSchema {
        string_pattern(
            Some("Parent entity in 'scene:<number>' format. Omit for scene root."),
            Some(7),
            Some(32),
            Some("^scene:[0-9]+$"),
        )
    }

    fn vec3() -> JsonSchema {
        array(number(None, None, None), None, Some(3), Some(3))
    }

    fn colour3() -> JsonSchema {
        array(number(None, Some(0.0), Some(1.0)), None, Some(3), Some(3))
    }

    fn colour4() -> JsonSchema {
        array(number(None, Some(0.0), Some(1.0)), None, Some(4), Some(4))
    }

    fn object(properties: &[(&str, JsonSchema)], required: &[&str]) -> JsonSchema {
        let mut map = BTreeMap::new();
        for (key, schema) in properties {
            map.insert((*key).to_string(), schema.clone());
        }
        object(
            map,
            required.iter().map(|key| (*key).to_string()).collect(),
            None,
            false,
        )
    }

    /// The Swift `write(...)` helper: defaults `required == ["entity_id"]` and a
    /// reversible write.
    fn write(
        title: &str,
        description: &str,
        properties: &[(&str, JsonSchema)],
        required: &[&str],
        access: CapabilityAccess,
    ) -> Spec {
        Spec {
            title: title.to_string(),
            description: description.to_string(),
            schema: Self::object(properties, required),
            access,
        }
    }

    fn write_reversible(title: &str, description: &str, properties: &[(&str, JsonSchema)]) -> Spec {
        Self::write(
            title,
            description,
            properties,
            &["entity_id"],
            CapabilityAccess::ReversibleWrite,
        )
    }

    fn script_value() -> JsonSchema {
        choice(vec![
            cove_agent::JsonSchema::string(None, None),
            cove_agent::JsonSchema::number(None, None),
            cove_agent::JsonSchema::boolean(),
            array(
                choice(vec![
                    cove_agent::JsonSchema::string(None, None),
                    cove_agent::JsonSchema::number(None, None),
                    cove_agent::JsonSchema::boolean(),
                ]),
                None,
                None,
                Some(256),
            ),
        ])
    }

    pub fn specifications() -> BTreeMap<String, Spec> {
        let mut specs = BTreeMap::new();
        let mut insert = |key: &str, spec: Spec| {
            specs.insert(key.to_string(), spec);
        };

        insert(
            "system.search_capabilities",
            Spec {
                title: "Search capabilities".to_string(),
                description: "Discover capabilities currently allowed for this project and scene."
                    .to_string(),
                schema: Self::object(
                    &[
                        ("query", cove_agent::JsonSchema::string(None, None)),
                        ("domain", cove_agent::JsonSchema::string(None, None)),
                        (
                            "access",
                            string_enum(
                                None,
                                &[
                                    "read",
                                    "reversible_write",
                                    "destructive_write",
                                    "external_side_effect",
                                ],
                            ),
                        ),
                    ],
                    &["query"],
                ),
                access: CapabilityAccess::Read,
            },
        );
        insert(
            "system.submit_plan",
            Spec {
                title: "Submit plan".to_string(),
                description:
                    "Submit ordered validated write draft ids for preview and user confirmation."
                        .to_string(),
                schema: Self::object(
                    &[
                        ("summary", cove_agent::JsonSchema::string(None, None)),
                        ("reasoning", cove_agent::JsonSchema::string(None, None)),
                        (
                            "draft_ids",
                            array(
                                cove_agent::JsonSchema::string(None, None),
                                None,
                                Some(0),
                                Some(crate::drafts::capability_draft_limits::CapabilityDraftLimits::MAXIMUM_DRAFTS_PER_PLAN),
                            ),
                        ),
                    ],
                    &["summary", "draft_ids"],
                ),
                access: CapabilityAccess::Read,
            },
        );
        insert(
            "scene.describe_components",
            Spec {
                title: "Describe components".to_string(),
                description: "Read registered scene components, required components, authored defaults, and field descriptions shared with the inspector. Field paths address stored component JSON; numeric scales describe display units.".to_string(),
                schema: Self::object(
                    &[("type_id", cove_agent::JsonSchema::string(None, None))],
                    &[],
                ),
                access: CapabilityAccess::Read,
            },
        );
        insert(
            "scene.get_entities",
            Spec {
                title: "Get scene entities".to_string(),
                description: "Read the AI-visible entity list for the current scene.".to_string(),
                schema: Self::object(&[], &[]),
                access: CapabilityAccess::Read,
            },
        );
        insert(
            "scene.get_selection",
            Spec {
                title: "Get selection".to_string(),
                description: "Read the currently selected scene entity.".to_string(),
                schema: Self::object(&[], &[]),
                access: CapabilityAccess::Read,
            },
        );
        insert(
            "scene.find_entities",
            Spec {
                title: "Find entities".to_string(),
                description: "Search entities by name, kind, component, or proximity.".to_string(),
                schema: Self::object(
                    &[
                        ("name", cove_agent::JsonSchema::string(None, None)),
                        ("kind", cove_agent::JsonSchema::string(None, None)),
                        ("component", cove_agent::JsonSchema::string(None, None)),
                        ("near_position", Self::vec3()),
                        ("near_radius", number(None, Some(0.0), None)),
                        ("limit", integer(None, Some(1), Some(200))),
                    ],
                    &[],
                ),
                access: CapabilityAccess::Read,
            },
        );

        insert(
            "scene.spawn_entity",
            Self::write(
                "Spawn entity",
                "Create a mesh, empty, light, or camera entity.",
                &[
                    ("label", cove_agent::JsonSchema::string(None, None)),
                    ("spawn_position", Self::vec3()),
                    (
                        "spawn_kind",
                        string_enum(None, &["mesh", "empty", "light", "camera"]),
                    ),
                    ("spawn_parent_id", Self::parent()),
                    (
                        "light_type",
                        string_enum(None, &["directional", "point", "spot"]),
                    ),
                    ("intensity", number(None, Some(0.0), None)),
                    ("color", Self::colour3()),
                    ("range", number(None, Some(0.0), None)),
                    ("light_cast_shadows", boolean()),
                    ("camera_fov_y", number(None, Some(1.0), Some(179.0))),
                ],
                &[],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.delete_entity",
            Self::write(
                "Delete entity",
                "Delete an entity and its authored scene state.",
                &[("entity_id", Self::entity())],
                &["entity_id"],
                CapabilityAccess::DestructiveWrite,
            ),
        );
        insert(
            "scene.duplicate_entity",
            Self::write_reversible(
                "Duplicate entity",
                "Duplicate an entity, optionally with a local-space offset.",
                &[
                    ("entity_id", Self::entity()),
                    ("duplicate_offset", Self::vec3()),
                ],
            ),
        );
        insert(
            "scene.reparent_entity",
            Self::write_reversible(
                "Reparent entity",
                "Move an entity beneath another entity or to the scene root.",
                &[("entity_id", Self::entity()), ("parent_id", Self::parent())],
            ),
        );
        insert(
            "scene.set_name",
            Self::write(
                "Rename entity",
                "Set an entity's display name.",
                &[
                    ("entity_id", Self::entity()),
                    ("name", cove_agent::JsonSchema::string(None, None)),
                ],
                &["entity_id", "name"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_transform",
            Self::write_reversible(
                "Set transform",
                "Set selected transform fields without overwriting omitted fields.",
                &[
                    ("entity_id", Self::entity()),
                    ("position", Self::vec3()),
                    ("euler_degrees", Self::vec3()),
                    (
                        "scale",
                        array(
                            number(None, Some(0.001), Some(1_000.0)),
                            None,
                            Some(3),
                            Some(3),
                        ),
                    ),
                ],
            ),
        );
        insert(
            "scene.snap_to_ground",
            Self::write_reversible(
                "Snap to ground",
                "Move an entity to ground plane y=0.",
                &[("entity_id", Self::entity())],
            ),
        );

        insert(
            "scene.set_light_type",
            Self::write(
                "Set light type",
                "Change a light to directional, point, or spot.",
                &[
                    ("entity_id", Self::entity()),
                    (
                        "light_type",
                        string_enum(None, &["directional", "point", "spot"]),
                    ),
                ],
                &["entity_id", "light_type"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_light_intensity",
            Self::write(
                "Set light intensity",
                "Set non-negative light intensity.",
                &[
                    ("entity_id", Self::entity()),
                    ("intensity", number(None, Some(0.0), None)),
                ],
                &["entity_id", "intensity"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_light_color",
            Self::write(
                "Set light colour",
                "Set linear RGB light colour.",
                &[("entity_id", Self::entity()), ("color", Self::colour3())],
                &["entity_id", "color"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_light_range",
            Self::write(
                "Set light range",
                "Set non-negative light range in metres.",
                &[
                    ("entity_id", Self::entity()),
                    ("range", number(None, Some(0.0), None)),
                ],
                &["entity_id", "range"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_light_spot_angles",
            Self::write_reversible(
                "Set spot angles",
                "Set the spot light inner and outer cone angles.",
                &[
                    ("entity_id", Self::entity()),
                    ("spot_inner_angle", number(None, Some(0.0), Some(180.0))),
                    ("spot_outer_angle", number(None, Some(0.0), Some(180.0))),
                ],
            ),
        );
        insert(
            "scene.set_light_cast_shadows",
            Self::write(
                "Set light shadows",
                "Enable or disable shadow casting for a light.",
                &[
                    ("entity_id", Self::entity()),
                    ("light_cast_shadows", boolean()),
                ],
                &["entity_id", "light_cast_shadows"],
                CapabilityAccess::ReversibleWrite,
            ),
        );

        insert(
            "scene.set_camera_pose",
            Self::write(
                "Set camera pose",
                "Set camera position and look-at target.",
                &[
                    ("entity_id", Self::entity()),
                    ("position", Self::vec3()),
                    ("camera_target", Self::vec3()),
                    ("camera_up", Self::vec3()),
                ],
                &["entity_id", "position", "camera_target"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_camera_fov",
            Self::write(
                "Set camera FOV",
                "Set vertical camera field of view in degrees.",
                &[
                    ("entity_id", Self::entity()),
                    ("camera_fov_y", number(None, Some(1.0), Some(179.0))),
                ],
                &["entity_id", "camera_fov_y"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_camera_aspect_ratio",
            Self::write(
                "Set camera aspect ratio",
                "Set the authored camera width/height ratio.",
                &[
                    ("entity_id", Self::entity()),
                    ("camera_aspect_ratio", number(None, Some(0.01), Some(100.0))),
                ],
                &["entity_id", "camera_aspect_ratio"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_camera_active",
            Self::write(
                "Set active camera",
                "Enable or disable this camera as the active render camera.",
                &[
                    ("entity_id", Self::entity()),
                    ("camera_is_active", boolean()),
                ],
                &["entity_id", "camera_is_active"],
                CapabilityAccess::ReversibleWrite,
            ),
        );

        insert(
            "scene.set_mesh_color",
            Self::write(
                "Set mesh colour",
                "Set the linear RGB colour tint of a render mesh.",
                &[("entity_id", Self::entity()), ("color", Self::colour3())],
                &["entity_id", "color"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_material",
            Self::write_reversible(
                "Set PBR material",
                "Update selected PBR material fields.",
                &[
                    ("entity_id", Self::entity()),
                    ("material_base_color", Self::colour4()),
                    ("material_metallic", number(None, Some(0.0), Some(1.0))),
                    ("material_roughness", number(None, Some(0.0), Some(1.0))),
                    ("material_emissive", Self::colour3()),
                ],
            ),
        );
        insert(
            "scene.set_mesh_visibility",
            Self::write(
                "Set mesh visibility",
                "Show or hide a render mesh.",
                &[("entity_id", Self::entity()), ("is_visible", boolean())],
                &["entity_id", "is_visible"],
                CapabilityAccess::ReversibleWrite,
            ),
        );

        insert(
            "scene.set_rigid_body_motion_type",
            Self::write(
                "Set rigid body motion",
                "Set static, dynamic, or kinematic motion.",
                &[
                    ("entity_id", Self::entity()),
                    (
                        "motion_type",
                        string_enum(None, &["static", "dynamic", "kinematic"]),
                    ),
                ],
                &["entity_id", "motion_type"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_rigid_body_mass",
            Self::write(
                "Set rigid body mass",
                "Set positive rigid body mass in kilograms.",
                &[
                    ("entity_id", Self::entity()),
                    ("mass", number(None, Some(0.0001), None)),
                ],
                &["entity_id", "mass"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_rigid_body_gravity_scale",
            Self::write(
                "Set gravity scale",
                "Set the rigid body's gravity multiplier.",
                &[
                    ("entity_id", Self::entity()),
                    ("gravity_scale", number(None, None, None)),
                ],
                &["entity_id", "gravity_scale"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_rigid_body_allow_sleep",
            Self::write(
                "Set rigid body sleeping",
                "Allow or prevent a rigid body from sleeping.",
                &[("entity_id", Self::entity()), ("allow_sleep", boolean())],
                &["entity_id", "allow_sleep"],
                CapabilityAccess::ReversibleWrite,
            ),
        );

        insert(
            "scene.set_collider_shape",
            Self::write(
                "Set collider shape",
                "Set box, sphere, capsule, mesh, or convex collider shape.",
                &[
                    ("entity_id", Self::entity()),
                    (
                        "collider_shape",
                        string_enum(
                            None,
                            &[
                                "box",
                                "sphere",
                                "capsule",
                                "cylinder",
                                "heightField",
                                "mesh",
                                "convex",
                            ],
                        ),
                    ),
                ],
                &["entity_id", "collider_shape"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_collider_box_extents",
            Self::write(
                "Set box collider extents",
                "Set positive box collider half extents.",
                &[
                    ("entity_id", Self::entity()),
                    (
                        "half_extents",
                        array(number(None, Some(0.0001), None), None, Some(3), Some(3)),
                    ),
                ],
                &["entity_id", "half_extents"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_collider_sphere_radius",
            Self::write(
                "Set sphere radius",
                "Set positive sphere collider radius.",
                &[
                    ("entity_id", Self::entity()),
                    ("radius", number(None, Some(0.0001), None)),
                ],
                &["entity_id", "radius"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_collider_capsule",
            Self::write(
                "Set capsule dimensions",
                "Set positive capsule radius and half-height.",
                &[
                    ("entity_id", Self::entity()),
                    ("radius", number(None, Some(0.0001), None)),
                    ("half_height", number(None, Some(0.0001), None)),
                ],
                &["entity_id"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_collider_material",
            Self::write_reversible(
                "Set collider material",
                "Update collider friction, restitution, or density.",
                &[
                    ("entity_id", Self::entity()),
                    ("friction", number(None, Some(0.0), Some(1.0))),
                    ("restitution", number(None, Some(0.0), Some(1.0))),
                    ("density", number(None, Some(0.0), None)),
                ],
            ),
        );
        insert(
            "scene.set_collider_trigger",
            Self::write(
                "Set collider trigger",
                "Enable or disable trigger behaviour.",
                &[("entity_id", Self::entity()), ("is_trigger", boolean())],
                &["entity_id", "is_trigger"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_collider_layer",
            Self::write_reversible(
                "Set collider layers",
                "Set collider layer id and interaction mask.",
                &[
                    ("entity_id", Self::entity()),
                    ("collider_layer_id", integer(None, Some(0), Some(15))),
                    ("collider_layer_mask", integer(None, Some(0), Some(65_535))),
                ],
            ),
        );
        insert(
            "scene.set_constraint_enabled",
            Self::write(
                "Set constraint enabled",
                "Enable or disable a physics constraint.",
                &[("entity_id", Self::entity()), ("is_enabled", boolean())],
                &["entity_id", "is_enabled"],
                CapabilityAccess::ReversibleWrite,
            ),
        );

        insert(
            "scene.set_audio_source",
            Self::write_reversible(
                "Set audio source",
                "Configure an entity's audio source.",
                &[
                    ("entity_id", Self::entity()),
                    ("audio_clip", cove_agent::JsonSchema::string(None, None)),
                    ("audio_volume", number(None, Some(0.0), Some(1.0))),
                    ("audio_pitch", number(None, Some(0.01), Some(4.0))),
                    ("audio_loop", boolean()),
                    ("audio_play_on_awake", boolean()),
                    ("audio_spatial_blend", number(None, Some(0.0), Some(1.0))),
                ],
            ),
        );
        insert(
            "scene.set_script_property",
            Self::write(
                "Set script property",
                "Set one bounded JSON script parameter value.",
                &[
                    ("entity_id", Self::entity()),
                    ("script_index", integer(None, Some(0), None)),
                    (
                        "script_property_name",
                        cove_agent::JsonSchema::string(None, None),
                    ),
                    ("script_property_value", Self::script_value()),
                ],
                &["entity_id", "script_property_name", "script_property_value"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_script_bindings",
            Self::write(
                "Set script enabled",
                "Enable or disable an existing script binding.",
                &[
                    ("entity_id", Self::entity()),
                    ("script_index", integer(None, Some(0), None)),
                    ("is_enabled", boolean()),
                ],
                &["entity_id", "is_enabled"],
                CapabilityAccess::ReversibleWrite,
            ),
        );
        insert(
            "scene.set_animation_player",
            Self::write_reversible(
                "Set animation player",
                "Configure animation clip playback.",
                &[
                    ("entity_id", Self::entity()),
                    ("animation_clip", cove_agent::JsonSchema::string(None, None)),
                    ("animation_speed", number(None, Some(0.0), None)),
                    ("animation_loop", boolean()),
                    ("animation_is_playing", boolean()),
                ],
            ),
        );

        specs
    }
}
