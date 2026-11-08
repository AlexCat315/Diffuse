//! AI-compatible scene edit plans: the legacy `SceneEditStep` wire format that
//! `SceneCapabilityDraftLowering` still produces while it remains.

use diffuse_kernel::codable::{format_double, serialize_double};
use serde::de::Error as DeError;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// A JSON-typed value that can be a string, number, boolean, or array.
/// Used for `set_script_property` where the AI sets a typed script parameter.
#[derive(Clone, Debug, PartialEq)]
pub enum JSONValue {
    String(String),
    Number(f64),
    Bool(bool),
    Array(Vec<JSONValue>),
}

impl Serialize for JSONValue {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            JSONValue::String(value) => serializer.serialize_str(value),
            JSONValue::Number(value) => serialize_double(value, serializer),
            JSONValue::Bool(value) => serializer.serialize_bool(*value),
            JSONValue::Array(values) => values.serialize(serializer),
        }
    }
}

impl<'de> Deserialize<'de> for JSONValue {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<JSONValue, D::Error> {
        // Swift decoded through a single-value container in the order
        // Bool, Double, [JSONValue], String. `serde_json::Value` already
        // distinguishes those JSON kinds, so the order collapses to a match.
        json_value_from(serde_json::Value::deserialize(deserializer)?).map_err(D::Error::custom)
    }
}

fn json_value_from(value: serde_json::Value) -> Result<JSONValue, String> {
    match value {
        serde_json::Value::Bool(value) => Ok(JSONValue::Bool(value)),
        serde_json::Value::Number(value) => value
            .as_f64()
            .map(JSONValue::Number)
            .ok_or_else(|| "number is not representable as Double".to_string()),
        serde_json::Value::String(value) => Ok(JSONValue::String(value)),
        serde_json::Value::Array(values) => values
            .into_iter()
            .map(json_value_from)
            .collect::<Result<Vec<JSONValue>, String>>()
            .map(JSONValue::Array),
        serde_json::Value::Null => Err("null is not a supported script value".to_string()),
        serde_json::Value::Object(_) => Err("object is not a supported script value".to_string()),
    }
}

impl JSONValue {
    /// Returns the value as its JSON representation for embedding in a JSON object.
    pub fn json_fragment(&self) -> String {
        match self {
            JSONValue::String(value) => {
                let escaped = value.replace('\\', "\\\\").replace('"', "\\\"");
                format!("\"{escaped}\"")
            }
            JSONValue::Number(value) => match format_double(*value) {
                Some(text) => text,
                None if value.is_nan() => "nan".to_string(),
                None if *value > 0.0 => "inf".to_string(),
                None => "-inf".to_string(),
            },
            JSONValue::Bool(value) => {
                if *value {
                    "true".to_string()
                } else {
                    "false".to_string()
                }
            }
            JSONValue::Array(values) => {
                let fragments: Vec<String> = values.iter().map(JSONValue::json_fragment).collect();
                format!("[{}]", fragments.join(","))
            }
        }
    }
}

/// Operations Claude can request in a `SceneEditStep`.
/// Each raw value is the JSON `"op"` string Claude returns.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum SceneEditOp {
    // Entity lifecycle
    #[serde(rename = "spawn_entity")]
    SpawnEntity,
    #[serde(rename = "delete_entity")]
    DeleteEntity,
    #[serde(rename = "duplicate_entity")]
    DuplicateEntity,
    #[serde(rename = "set_name")]
    SetName,
    #[serde(rename = "reparent_entity")]
    ReparentEntity,

    // Spatial
    #[serde(rename = "set_transform")]
    SetTransform,
    #[serde(rename = "snap_to_ground")]
    SnapToGround,

    // Lighting
    #[serde(rename = "set_light_type")]
    SetLightType,
    #[serde(rename = "set_light_intensity")]
    SetLightIntensity,
    #[serde(rename = "set_light_color")]
    SetLightColor,
    #[serde(rename = "set_light_range")]
    SetLightRange,
    #[serde(rename = "set_light_spot_angles")]
    SetLightSpotAngles,
    #[serde(rename = "set_light_cast_shadows")]
    SetLightCastShadows,

    // Camera
    #[serde(rename = "set_camera_pose")]
    SetCameraPose,
    #[serde(rename = "set_camera_fov")]
    SetCameraFov,
    #[serde(rename = "set_camera_aspect_ratio")]
    SetCameraAspectRatio,
    #[serde(rename = "set_camera_active")]
    SetCameraActive,

    // Visual
    #[serde(rename = "set_mesh_color")]
    SetMeshColor,
    #[serde(rename = "set_material")]
    SetMaterial,

    // Physics — rigidbody
    #[serde(rename = "set_rigidbody_motion")]
    SetRigidBodyMotion,
    #[serde(rename = "set_rigidbody_mass")]
    SetRigidBodyMass,
    #[serde(rename = "set_rigidbody_gravity")]
    SetRigidBodyGravity,
    #[serde(rename = "set_rigidbody_allow_sleep")]
    SetRigidBodyAllowSleep,

    // Physics — collider shape
    #[serde(rename = "set_collider_shape")]
    SetColliderShape,
    #[serde(rename = "set_collider_box_extents")]
    SetColliderBoxExtents,
    #[serde(rename = "set_collider_sphere_radius")]
    SetColliderSphereRadius,
    #[serde(rename = "set_collider_capsule")]
    SetColliderCapsule,

    // Physics — collider material
    #[serde(rename = "set_collider_material")]
    SetColliderMaterial,

    // Physics — misc
    #[serde(rename = "set_collider_trigger")]
    SetColliderTrigger,
    #[serde(rename = "set_collider_layer")]
    SetColliderLayer,
    #[serde(rename = "set_constraint_enabled")]
    SetConstraintEnabled,

    // Audio
    #[serde(rename = "set_audio_source")]
    SetAudioSource,

    // Script
    #[serde(rename = "set_script_property")]
    SetScriptProperty,
    #[serde(rename = "set_script_enabled")]
    SetScriptEnabled,

    // Mesh visibility
    #[serde(rename = "set_mesh_visibility")]
    SetMeshVisibility,

    // Animation
    #[serde(rename = "set_animation_player")]
    SetAnimationPlayer,
}

impl SceneEditOp {
    /// Swift's `CaseIterable` order.
    pub const ALL: [SceneEditOp; 36] = [
        SceneEditOp::SpawnEntity,
        SceneEditOp::DeleteEntity,
        SceneEditOp::DuplicateEntity,
        SceneEditOp::SetName,
        SceneEditOp::ReparentEntity,
        SceneEditOp::SetTransform,
        SceneEditOp::SnapToGround,
        SceneEditOp::SetLightType,
        SceneEditOp::SetLightIntensity,
        SceneEditOp::SetLightColor,
        SceneEditOp::SetLightRange,
        SceneEditOp::SetLightSpotAngles,
        SceneEditOp::SetLightCastShadows,
        SceneEditOp::SetCameraPose,
        SceneEditOp::SetCameraFov,
        SceneEditOp::SetCameraAspectRatio,
        SceneEditOp::SetCameraActive,
        SceneEditOp::SetMeshColor,
        SceneEditOp::SetMaterial,
        SceneEditOp::SetRigidBodyMotion,
        SceneEditOp::SetRigidBodyMass,
        SceneEditOp::SetRigidBodyGravity,
        SceneEditOp::SetRigidBodyAllowSleep,
        SceneEditOp::SetColliderShape,
        SceneEditOp::SetColliderBoxExtents,
        SceneEditOp::SetColliderSphereRadius,
        SceneEditOp::SetColliderCapsule,
        SceneEditOp::SetColliderMaterial,
        SceneEditOp::SetColliderTrigger,
        SceneEditOp::SetColliderLayer,
        SceneEditOp::SetConstraintEnabled,
        SceneEditOp::SetAudioSource,
        SceneEditOp::SetScriptProperty,
        SceneEditOp::SetScriptEnabled,
        SceneEditOp::SetMeshVisibility,
        SceneEditOp::SetAnimationPlayer,
    ];

    /// The JSON `"op"` string Claude returns.
    pub const fn raw_value(self) -> &'static str {
        match self {
            SceneEditOp::SpawnEntity => "spawn_entity",
            SceneEditOp::DeleteEntity => "delete_entity",
            SceneEditOp::DuplicateEntity => "duplicate_entity",
            SceneEditOp::SetName => "set_name",
            SceneEditOp::ReparentEntity => "reparent_entity",
            SceneEditOp::SetTransform => "set_transform",
            SceneEditOp::SnapToGround => "snap_to_ground",
            SceneEditOp::SetLightType => "set_light_type",
            SceneEditOp::SetLightIntensity => "set_light_intensity",
            SceneEditOp::SetLightColor => "set_light_color",
            SceneEditOp::SetLightRange => "set_light_range",
            SceneEditOp::SetLightSpotAngles => "set_light_spot_angles",
            SceneEditOp::SetLightCastShadows => "set_light_cast_shadows",
            SceneEditOp::SetCameraPose => "set_camera_pose",
            SceneEditOp::SetCameraFov => "set_camera_fov",
            SceneEditOp::SetCameraAspectRatio => "set_camera_aspect_ratio",
            SceneEditOp::SetCameraActive => "set_camera_active",
            SceneEditOp::SetMeshColor => "set_mesh_color",
            SceneEditOp::SetMaterial => "set_material",
            SceneEditOp::SetRigidBodyMotion => "set_rigidbody_motion",
            SceneEditOp::SetRigidBodyMass => "set_rigidbody_mass",
            SceneEditOp::SetRigidBodyGravity => "set_rigidbody_gravity",
            SceneEditOp::SetRigidBodyAllowSleep => "set_rigidbody_allow_sleep",
            SceneEditOp::SetColliderShape => "set_collider_shape",
            SceneEditOp::SetColliderBoxExtents => "set_collider_box_extents",
            SceneEditOp::SetColliderSphereRadius => "set_collider_sphere_radius",
            SceneEditOp::SetColliderCapsule => "set_collider_capsule",
            SceneEditOp::SetColliderMaterial => "set_collider_material",
            SceneEditOp::SetColliderTrigger => "set_collider_trigger",
            SceneEditOp::SetColliderLayer => "set_collider_layer",
            SceneEditOp::SetConstraintEnabled => "set_constraint_enabled",
            SceneEditOp::SetAudioSource => "set_audio_source",
            SceneEditOp::SetScriptProperty => "set_script_property",
            SceneEditOp::SetScriptEnabled => "set_script_enabled",
            SceneEditOp::SetMeshVisibility => "set_mesh_visibility",
            SceneEditOp::SetAnimationPlayer => "set_animation_player",
        }
    }

    /// Registered capability that authorises this compatibility plan operation.
    /// This is the only mapping between the legacy wire name and the capability id.
    pub const fn capability_id(self) -> &'static str {
        match self {
            SceneEditOp::SpawnEntity => "scene.spawn_entity",
            SceneEditOp::DeleteEntity => "scene.delete_entity",
            SceneEditOp::DuplicateEntity => "scene.duplicate_entity",
            SceneEditOp::SetName => "scene.set_name",
            SceneEditOp::ReparentEntity => "scene.reparent_entity",
            SceneEditOp::SetTransform => "scene.set_transform",
            SceneEditOp::SnapToGround => "scene.snap_to_ground",
            SceneEditOp::SetLightType => "scene.set_light_type",
            SceneEditOp::SetLightIntensity => "scene.set_light_intensity",
            SceneEditOp::SetLightColor => "scene.set_light_color",
            SceneEditOp::SetLightRange => "scene.set_light_range",
            SceneEditOp::SetLightSpotAngles => "scene.set_light_spot_angles",
            SceneEditOp::SetLightCastShadows => "scene.set_light_cast_shadows",
            SceneEditOp::SetCameraPose => "scene.set_camera_pose",
            SceneEditOp::SetCameraFov => "scene.set_camera_fov",
            SceneEditOp::SetCameraAspectRatio => "scene.set_camera_aspect_ratio",
            SceneEditOp::SetCameraActive => "scene.set_camera_active",
            SceneEditOp::SetMeshColor => "scene.set_mesh_color",
            SceneEditOp::SetMaterial => "scene.set_material",
            SceneEditOp::SetRigidBodyMotion => "scene.set_rigid_body_motion_type",
            SceneEditOp::SetRigidBodyMass => "scene.set_rigid_body_mass",
            SceneEditOp::SetRigidBodyGravity => "scene.set_rigid_body_gravity_scale",
            SceneEditOp::SetRigidBodyAllowSleep => "scene.set_rigid_body_allow_sleep",
            SceneEditOp::SetColliderShape => "scene.set_collider_shape",
            SceneEditOp::SetColliderBoxExtents => "scene.set_collider_box_extents",
            SceneEditOp::SetColliderSphereRadius => "scene.set_collider_sphere_radius",
            SceneEditOp::SetColliderCapsule => "scene.set_collider_capsule",
            SceneEditOp::SetColliderMaterial => "scene.set_collider_material",
            SceneEditOp::SetColliderTrigger => "scene.set_collider_trigger",
            SceneEditOp::SetColliderLayer => "scene.set_collider_layer",
            SceneEditOp::SetConstraintEnabled => "scene.set_constraint_enabled",
            SceneEditOp::SetAudioSource => "scene.set_audio_source",
            SceneEditOp::SetScriptProperty => "scene.set_script_property",
            SceneEditOp::SetScriptEnabled => "scene.set_script_bindings",
            SceneEditOp::SetMeshVisibility => "scene.set_mesh_visibility",
            SceneEditOp::SetAnimationPlayer => "scene.set_animation_player",
        }
    }

    pub fn from_capability_id(capability_id: &str) -> Option<SceneEditOp> {
        SceneEditOp::ALL
            .into_iter()
            .find(|operation| operation.capability_id() == capability_id)
    }
}

mod float_serde {
    use serde::Serializer;
    use serde::ser::{Error as SerError, SerializeSeq};

    pub fn optional_float<S: Serializer>(
        value: &Option<f32>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        match value {
            Some(value) => diffuse_kernel::codable::serialize_float(value, serializer),
            None => serializer.serialize_none(),
        }
    }

    pub fn float_vec<S: Serializer>(
        value: &Option<Vec<f32>>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        let Some(values) = value else {
            return serializer.serialize_none();
        };
        let mut sequence = serializer.serialize_seq(Some(values.len()))?;
        for value in values {
            let text = diffuse_kernel::codable::format_float(*value).ok_or_else(|| {
                S::Error::custom(
                    "Swift JSONEncoder rejects NaN and infinity in persisted documents",
                )
            })?;
            let raw = serde_json::value::RawValue::from_string(text)
                .map_err(|_| S::Error::custom("invalid number produced for a Float"))?;
            sequence.serialize_element(raw.as_ref())?;
        }
        sequence.end()
    }
}

/// One atomic mutation step in a `SceneEditPlan`.
///
/// All fields except `op` and `entity_ref` are optional. Which fields are
/// required for each `op` is described in `AIScenePlanner`'s tool schema.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SceneEditStep {
    pub op: SceneEditOp,

    /// Target entity — `"scene:<rawID>"`. Not required for `spawn_entity`.
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "entity_id")]
    pub entity_ref: Option<String>,

    // spawn_entity
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::float_vec",
        rename = "spawn_position"
    )]
    pub spawn_position: Option<Vec<f32>>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "spawn_kind"
    )]
    pub spawn_kind: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "spawn_parent_id"
    )]
    pub spawn_parent_ref: Option<String>,

    // duplicate_entity
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::float_vec",
        rename = "duplicate_offset"
    )]
    pub duplicate_offset: Option<Vec<f32>>,

    // set_transform / snap_to_ground
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::float_vec"
    )]
    pub position: Option<Vec<f32>>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::float_vec",
        rename = "euler_degrees"
    )]
    pub euler_degrees: Option<Vec<f32>>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::float_vec"
    )]
    pub scale: Option<Vec<f32>>,

    // set_name
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    // set_light_type
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "light_type"
    )]
    pub light_type: Option<String>,

    // set_light_intensity
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float"
    )]
    pub intensity: Option<f32>,

    // set_light_color
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::float_vec"
    )]
    pub color: Option<Vec<f32>>,

    // set_light_range
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float"
    )]
    pub range: Option<f32>,

    // set_light_spot_angles
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float",
        rename = "spot_inner_angle"
    )]
    pub spot_inner_angle_degrees: Option<f32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float",
        rename = "spot_outer_angle"
    )]
    pub spot_outer_angle_degrees: Option<f32>,

    // set_camera_pose
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::float_vec",
        rename = "camera_target"
    )]
    pub camera_target: Option<Vec<f32>>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::float_vec",
        rename = "camera_up"
    )]
    pub camera_up: Option<Vec<f32>>,

    // set_rigidbody_motion
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "motion_type"
    )]
    pub motion_type: Option<String>,

    // set_rigidbody_mass
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float"
    )]
    pub mass: Option<f32>,

    // set_rigidbody_gravity
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float",
        rename = "gravity_scale"
    )]
    pub gravity_scale: Option<f32>,

    // set_rigidbody_allow_sleep
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "allow_sleep"
    )]
    pub allow_sleep: Option<bool>,

    // set_collider_shape
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "collider_shape"
    )]
    pub collider_shape: Option<String>,

    // set_collider_box_extents
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::float_vec",
        rename = "half_extents"
    )]
    pub half_extents: Option<Vec<f32>>,

    // set_collider_sphere_radius / set_collider_capsule
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float"
    )]
    pub radius: Option<f32>,

    // set_collider_capsule
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float",
        rename = "half_height"
    )]
    pub half_height: Option<f32>,

    // set_collider_material
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float"
    )]
    pub friction: Option<f32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float"
    )]
    pub restitution: Option<f32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float"
    )]
    pub density: Option<f32>,

    // set_collider_trigger
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "is_trigger"
    )]
    pub is_trigger: Option<bool>,

    // set_collider_layer
    /// Physics layer this collider occupies (0-15).
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "collider_layer_id"
    )]
    pub collider_layer_id: Option<i64>,
    /// Bitmask of layers this collider interacts with.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "collider_layer_mask"
    )]
    pub collider_layer_mask: Option<i64>,

    // set_constraint_enabled
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "is_enabled"
    )]
    pub is_enabled: Option<bool>,

    // reparent_entity
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "parent_id")]
    pub parent_ref: Option<String>,

    // set_audio_source
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "audio_clip"
    )]
    pub audio_clip: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float",
        rename = "audio_volume"
    )]
    pub audio_volume: Option<f32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float",
        rename = "audio_pitch"
    )]
    pub audio_pitch: Option<f32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "audio_loop"
    )]
    pub audio_loop: Option<bool>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "audio_play_on_awake"
    )]
    pub audio_play_on_awake: Option<bool>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float",
        rename = "audio_spatial_blend"
    )]
    pub audio_spatial_blend: Option<f32>,

    // set_script_property
    /// Binding index, default 0.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "script_index"
    )]
    pub script_index: Option<i64>,
    /// Stable catalog id; creates/replaces binding when provided.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "script_identifier"
    )]
    pub script_identifier: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "script_property_name"
    )]
    pub script_property_name: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "script_property_value"
    )]
    pub script_property_value: Option<JSONValue>,

    // set_material (PBR)
    /// Linear 0-1; `None` = unchanged.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::float_vec",
        rename = "material_base_color"
    )]
    pub material_base_color: Option<Vec<f32>>,
    /// 0-1; `None` = unchanged.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float",
        rename = "material_metallic"
    )]
    pub material_metallic: Option<f32>,
    /// 0-1; `None` = unchanged.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float",
        rename = "material_roughness"
    )]
    pub material_roughness: Option<f32>,
    /// Linear 0-1; `None` = no emission.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::float_vec",
        rename = "material_emissive"
    )]
    pub material_emissive: Option<Vec<f32>>,

    // set_light_cast_shadows
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "light_cast_shadows"
    )]
    pub light_cast_shadows: Option<bool>,

    // set_camera_fov / set_camera_aspect_ratio / set_camera_active
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float",
        rename = "camera_fov_y"
    )]
    pub camera_fov_y_degrees: Option<f32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float",
        rename = "camera_aspect_ratio"
    )]
    pub camera_aspect_ratio: Option<f32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "camera_is_active"
    )]
    pub camera_is_active: Option<bool>,

    // set_mesh_visibility
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "is_visible"
    )]
    pub is_visible: Option<bool>,

    // set_animation_player
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "animation_clip"
    )]
    pub animation_clip: Option<String>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "float_serde::optional_float",
        rename = "animation_speed"
    )]
    pub animation_speed: Option<f32>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "animation_loop"
    )]
    pub animation_loop: Option<bool>,
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "animation_is_playing"
    )]
    pub animation_is_playing: Option<bool>,
}

/// A multi-step AI-generated scene edit plan.
/// Decoded from Claude's `execute_edit_plan` tool call input.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SceneEditPlan {
    /// One-line description of what the plan achieves.
    pub summary: String,

    /// Claude's reasoning — useful for debugging and training logs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<String>,

    /// Ordered list of mutations to execute atomically.
    pub steps: Vec<SceneEditStep>,

    /// Compatibility transports such as MCP echo the scene revision they read.
    /// Native AI sessions carry the same authority on `Proposal`.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "scene_revision"
    )]
    pub scene_revision: Option<u64>,
}

impl SceneEditPlan {
    pub fn new(summary: String, reasoning: Option<String>, steps: Vec<SceneEditStep>) -> Self {
        Self {
            summary,
            reasoning,
            steps,
            scene_revision: None,
        }
    }

    pub fn is_empty(&self) -> bool {
        self.steps.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::{JSONValue, SceneEditOp, SceneEditPlan, SceneEditStep};

    #[test]
    fn edit_step_keys_match_swift_coding_keys() {
        let step: SceneEditStep = serde_json::from_str(
            r#"{"op":"set_script_enabled","entity_id":"scene:1","is_enabled":false}"#,
        )
        .expect("decode");
        assert_eq!(step.op, SceneEditOp::SetScriptEnabled);
        assert_eq!(step.entity_ref.as_deref(), Some("scene:1"));
        assert_eq!(step.is_enabled, Some(false));

        let encoded = serde_json::to_value(&step).expect("encode");
        assert_eq!(encoded["op"], "set_script_enabled");
        assert_eq!(encoded["entity_id"], "scene:1");
        assert_eq!(encoded["is_enabled"], false);
        assert!(encoded.get("script_index").is_none());
    }

    #[test]
    fn script_property_values_round_trip_and_render_fragments() {
        let value: JSONValue =
            serde_json::from_str(r#"[1, 2.5, true, "x\"y"]"#).expect("decode array");
        assert_eq!(
            value,
            JSONValue::Array(vec![
                JSONValue::Number(1.0),
                JSONValue::Number(2.5),
                JSONValue::Bool(true),
                JSONValue::String("x\"y".to_string()),
            ])
        );
        assert_eq!(value.json_fragment(), r#"[1,2.5,true,"x\"y"]"#);
    }

    #[test]
    fn plan_tolerates_missing_reasoning_and_revision() {
        let plan: SceneEditPlan = serde_json::from_str(r#"{"summary":"s","steps":[]}"#).unwrap();
        assert!(plan.is_empty());
        assert!(plan.reasoning.is_none());
        assert!(plan.scene_revision.is_none());
        let encoded = serde_json::to_value(&plan).unwrap();
        assert!(encoded.get("reasoning").is_none());
        assert!(encoded.get("scene_revision").is_none());
    }
}
