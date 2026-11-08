//! Compact, serialisable snapshot of the scene for AI planning.
//!
//! Built by `SceneSemanticEncoder` from a live `SceneRuntime`; passed verbatim
//! to `AIScenePlanner` as the context Claude reasons over.
//!
//! Optional fields are omitted on encode and default to `None` on decode,
//! matching Swift's synthesised `encodeIfPresent`/`decodeIfPresent`.

use serde::{Deserialize, Serialize};

/// Compact snapshot of a single `ScriptBinding` for AI context.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SceneSemanticSnapshotScriptBindingRecord {
    pub handle: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub identifier: Option<String>,
    pub is_enabled: bool,
    /// Raw JSON string of parameters (e.g. `{"speed":5,"label":"Patrol"}`).
    #[serde(rename = "parametersJSON")]
    pub parameters_json: String,
}

impl SceneSemanticSnapshotScriptBindingRecord {
    pub fn new(
        handle: u64,
        identifier: Option<String>,
        is_enabled: bool,
        parameters_json: String,
    ) -> Self {
        Self {
            handle,
            identifier,
            is_enabled,
            parameters_json,
        }
    }
}

/// One entity's AI-visible authored state.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SceneSemanticSnapshotEntity {
    /// Stable entity reference formatted as `"scene:<rawID>"`.
    pub id: String,
    /// Human-readable name from `SceneNameComponent`, or `"Entity <rawID>"`.
    pub name: String,
    /// Kind label from `SceneKindComponent`, or derived from components present.
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_ref: Option<String>,
    pub child_refs: Vec<String>,
    pub is_selected: bool,
    /// Local-space position in metres.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub position: Option<Vec<f32>>,
    /// Local-space scale factors; `None` when uniform 1,1,1 or no transform.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scale: Option<Vec<f32>>,
    /// Local-space XYZ intrinsic Euler angles in degrees.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub euler_degrees: Option<Vec<f32>>,
    /// World-space position in metres.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub world_position: Option<Vec<f32>>,
    /// World-space XYZ intrinsic Euler angles in degrees.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub world_euler_degrees: Option<Vec<f32>>,
    /// Cumulative world-space scale.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub world_scale: Option<Vec<f32>>,
    /// Component type names present on this entity.
    pub components: Vec<String>,

    // Light extras — present only when `"light"` is in `components`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub light_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub light_intensity: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub light_color: Option<Vec<f32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub light_range: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub light_spot_inner: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub light_spot_outer: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub light_cast_shadows: Option<bool>,

    // Camera extras — present only when `"camera"` is in `components`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub camera_fov_y_degrees: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub camera_is_active: Option<bool>,

    // Mesh extras.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mesh_color: Option<Vec<f32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub material_base_color: Option<Vec<f32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub material_metallic: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub material_roughness: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub material_emissive: Option<Vec<f32>>,

    // Physics — rigidbody.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rigid_body_motion_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rigid_body_mass: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rigid_body_gravity_scale: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rigid_body_allow_sleep: Option<bool>,

    // Physics — collider.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collider_shape: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collider_box_half_extents: Option<Vec<f32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collider_sphere_radius: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collider_capsule_radius: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collider_capsule_half_height: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collider_is_trigger: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collider_friction: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collider_restitution: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collider_density: Option<f32>,
    #[serde(rename = "colliderLayerID", skip_serializing_if = "Option::is_none")]
    pub collider_layer_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub collider_layer_mask: Option<i64>,

    // Audio.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_clip: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_volume: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_loop: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_play_on_awake: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_pitch: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audio_spatial_blend: Option<f32>,

    // Mesh visibility (authored) — `None` means default true.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mesh_is_visible: Option<bool>,

    // Animation.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub animation_clip: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub animation_speed: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub animation_loop: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub animation_is_playing: Option<bool>,

    // Script.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub script_bindings: Option<Vec<SceneSemanticSnapshotScriptBindingRecord>>,

    // Constraint.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub constraint_enabled: Option<bool>,

    // Ragdoll.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ragdoll_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ragdoll_blend_weight: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ragdoll_bone_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ragdoll_simulated_bone_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ragdoll_is_enabled: Option<bool>,

    // Vehicle — authored configuration plus the latest physics frame state.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vehicle_is_enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vehicle_controller_kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vehicle_wheel_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vehicle_differential_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vehicle_transmission_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vehicle_max_torque: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vehicle_forward_speed: Option<f32>,
    #[serde(rename = "vehicleEngineRPM", skip_serializing_if = "Option::is_none")]
    pub vehicle_engine_rpm: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vehicle_current_gear: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vehicle_wheel_contact_count: Option<i64>,

    // Soft-body / cloth — authored topology plus latest streamed state.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_body_is_enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_body_pressure: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_body_linear_damping: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_body_vertex_radius: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_body_is_sleeping: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_body_deformed_vertex_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cloth_grid_size_x: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cloth_grid_size_z: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cloth_spacing: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cloth_fixed_vertex_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cloth_bend_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_body_topology_kind: Option<String>,
    #[serde(
        rename = "softBodyMeshResourceID",
        skip_serializing_if = "Option::is_none"
    )]
    pub soft_body_mesh_resource_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_body_mesh_vertex_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_body_mesh_triangle_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_body_mesh_tetrahedron_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_body_mesh_fixed_vertex_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_body_mesh_bend_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_body_mesh_volume_compliance: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub soft_body_mesh_geometry_revision: Option<u64>,

    // Pre-fractured destruction — authored policy plus runtime activation state.
    #[serde(
        rename = "destructibleAssetResourceID",
        skip_serializing_if = "Option::is_none"
    )]
    pub destructible_asset_resource_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_is_enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_damage_threshold: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_impulse_threshold: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_fragment_budget: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_maximum_fragment_lifetime_seconds: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_sleeping_recycle_delay_seconds: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_separation_impulse: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_asset_revision: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_asset_fragment_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_asset_connection_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_has_fractured: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_is_fully_fractured: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_active_fragment_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_broken_connection_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_released_fragment_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructible_retained_fragment_count: Option<i64>,
}

/// Root snapshot record handed to the planner.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SceneSemanticSnapshot {
    pub scene_revision: u64,
    pub entity_count: i64,
    pub entities: Vec<SceneSemanticSnapshotEntity>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selected_ref: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub locale_identifier: Option<String>,
}

impl SceneSemanticSnapshot {
    pub fn new(
        scene_revision: u64,
        entity_count: i64,
        entities: Vec<SceneSemanticSnapshotEntity>,
    ) -> Self {
        Self {
            scene_revision,
            entity_count,
            entities,
            selected_ref: None,
            workspace_mode: None,
            locale_identifier: None,
        }
    }

    pub fn with_selected_ref(mut self, selected_ref: Option<String>) -> Self {
        self.selected_ref = selected_ref;
        self
    }

    pub fn with_workspace_mode(mut self, workspace_mode: Option<String>) -> Self {
        self.workspace_mode = workspace_mode;
        self
    }

    pub fn with_locale_identifier(mut self, locale_identifier: Option<String>) -> Self {
        self.locale_identifier = locale_identifier;
        self
    }
}
