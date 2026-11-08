//! Session's incrementally maintained, AI-visible model of the world.
//!
//! The three layers mirror architecture.md §World:
//! - `authored` — explicit properties (typed fields below), permanent truth
//! - `evaluated` — engine-computed derived values (world-space transform, etc.)
//! - `inferred` — AI semantic annotations with confidence scores

use std::collections::BTreeMap;

use diffuse_intent::transactions::world_event::{WorldEvent, WorldPropertyValue};
use diffuse_kernel::codable::{format_float, serialize_double};
use diffuse_observation::event_symbolic_view::format_general;
use diffuse_perception::SwiftDate;
use diffuse_scene::components::core::value::ComponentValue;
use serde::{Deserialize, Serialize};

use crate::semantic::scene_semantic_snapshot::{
    SceneSemanticSnapshot, SceneSemanticSnapshotScriptBindingRecord,
};

/// Human-readable string used when storing a `WorldPropertyValue` as an
/// `InferredProperty`.
///
/// Rendered as an extension trait because Rust forbids inherent impls on
/// foreign types.
pub trait InferredDisplayValue {
    fn inferred_display_value(&self) -> String;
}

impl InferredDisplayValue for WorldPropertyValue {
    fn inferred_display_value(&self) -> String {
        match self {
            WorldPropertyValue::String(value) => value.clone(),
            WorldPropertyValue::Float(value) => format_general(f64::from(*value), 4),
            WorldPropertyValue::Bool(value) => value.to_string(),
            WorldPropertyValue::Json(value) => {
                serde_json::to_string(&value.to_json_value()).unwrap_or_default()
            }
            WorldPropertyValue::Vec3(x, y, z) => format!(
                "({}, {}, {})",
                swift_float_description(*x),
                swift_float_description(*y),
                swift_float_description(*z)
            ),
            WorldPropertyValue::Vec4(x, y, z, w) => format!(
                "({}, {}, {}, {})",
                swift_float_description(*x),
                swift_float_description(*y),
                swift_float_description(*z),
                swift_float_description(*w)
            ),
        }
    }
}

/// Swift's `"\(float)"`: shortest round-trip text, with a fractional `.0` kept
/// on integral values.
fn swift_float_description(value: f32) -> String {
    let text = format_float(value).unwrap_or_else(|| "nan".to_string());
    if !text.contains('.') && !text.contains('e') && !text.contains('E') {
        format!("{text}.0")
    } else {
        text
    }
}

/// An AI-inferred semantic annotation on an entity, tagged with confidence and
/// optional source.
///
/// The `authored` layer can always override `inferred` — see architecture.md §World.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InferredProperty {
    /// String representation of the inferred value.
    pub display_value: String,
    /// Confidence score in [0, 1] from the producing pipeline or Session.
    #[serde(serialize_with = "serialize_double")]
    pub confidence: f64,
    /// Identifier of the pipeline or model that produced this annotation.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

impl InferredProperty {
    pub fn new(display_value: String, confidence: f64) -> Self {
        Self {
            display_value,
            confidence,
            source: None,
        }
    }
}

/// An entity's full AI-visible state as maintained by `WorldView`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorldEntityRecord {
    #[serde(rename = "ref")]
    pub ref_: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_ref: Option<String>,
    pub child_refs: Vec<String>,
    /// Component tags present on the entity.
    /// Populated from `SceneSemanticSnapshot`; not updated incrementally by
    /// `WorldEvent`s.
    pub components: Vec<String>,
    // Transform (authored)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub position: Option<Vec<f32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scale: Option<Vec<f32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub euler_degrees: Option<Vec<f32>>,
    // Light (authored)
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
    // Camera (authored)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub camera_fov_y_degrees: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub camera_is_active: Option<bool>,
    // Mesh (authored)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mesh_color: Option<Vec<f32>>,
    // PBR material (authored)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub material_base_color: Option<Vec<f32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub material_metallic: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub material_roughness: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub material_emissive: Option<Vec<f32>>,
    // Physics — rigidbody (authored)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rigid_body_motion_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rigid_body_mass: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rigid_body_gravity_scale: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rigid_body_allow_sleep: Option<bool>,
    // Physics — collider (authored)
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
    // Audio (authored)
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
    // Mesh visibility (authored) — `None` means default true (visible)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mesh_is_visible: Option<bool>,
    // Animation (authored)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub animation_clip: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub animation_speed: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub animation_loop: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub animation_is_playing: Option<bool>,
    // Constraint (authored)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub constraint_enabled: Option<bool>,
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
    // Script bindings (authored)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub script_bindings: Option<Vec<SceneSemanticSnapshotScriptBindingRecord>>,
    // Selection state (not authored — updated by selectionChanged events)
    pub is_selected: bool,
    /// Engine-computed derived properties (e.g. "worldPosition", "worldScale").
    pub evaluated: BTreeMap<String, WorldPropertyValue>,
    /// AI semantic annotations (e.g. "semanticRole": "hero_character").
    pub inferred: BTreeMap<String, InferredProperty>,
}

impl WorldEntityRecord {
    pub fn new(ref_: String) -> Self {
        Self {
            ref_,
            name: String::new(),
            kind: None,
            parent_ref: None,
            child_refs: Vec::new(),
            components: Vec::new(),
            position: None,
            scale: None,
            euler_degrees: None,
            light_type: None,
            light_intensity: None,
            light_color: None,
            light_range: None,
            light_spot_inner: None,
            light_spot_outer: None,
            light_cast_shadows: None,
            camera_fov_y_degrees: None,
            camera_is_active: None,
            mesh_color: None,
            material_base_color: None,
            material_metallic: None,
            material_roughness: None,
            material_emissive: None,
            rigid_body_motion_type: None,
            rigid_body_mass: None,
            rigid_body_gravity_scale: None,
            rigid_body_allow_sleep: None,
            collider_shape: None,
            collider_box_half_extents: None,
            collider_sphere_radius: None,
            collider_capsule_radius: None,
            collider_capsule_half_height: None,
            collider_is_trigger: None,
            collider_friction: None,
            collider_restitution: None,
            collider_density: None,
            collider_layer_id: None,
            collider_layer_mask: None,
            audio_clip: None,
            audio_volume: None,
            audio_loop: None,
            audio_play_on_awake: None,
            audio_pitch: None,
            audio_spatial_blend: None,
            mesh_is_visible: None,
            animation_clip: None,
            animation_speed: None,
            animation_loop: None,
            animation_is_playing: None,
            constraint_enabled: None,
            ragdoll_mode: None,
            ragdoll_blend_weight: None,
            ragdoll_bone_count: None,
            ragdoll_simulated_bone_count: None,
            ragdoll_is_enabled: None,
            script_bindings: None,
            is_selected: false,
            evaluated: BTreeMap::new(),
            inferred: BTreeMap::new(),
        }
    }

    /// Applies a single authored property change from a `WorldEvent`.
    pub fn apply(&mut self, property: String, value: WorldPropertyValue) {
        if let Some(type_id) = property.strip_prefix("components.") {
            if let WorldPropertyValue::Json(data) = value {
                if data == ComponentValue::Null {
                    self.components.retain(|component| component != type_id);
                } else if !self.components.iter().any(|component| component == type_id) {
                    self.components.push(type_id.to_string());
                }
            }
            return;
        }
        match property.as_str() {
            "name" => {
                if let WorldPropertyValue::String(value) = value {
                    self.name = value;
                }
            }
            "kind" => {
                if let WorldPropertyValue::String(value) = value {
                    self.kind = Some(value);
                }
            }
            "position" => {
                if let WorldPropertyValue::Vec3(x, y, z) = value {
                    self.position = Some(vec![x, y, z]);
                }
            }
            "scale" => {
                if let WorldPropertyValue::Vec3(x, y, z) = value {
                    self.scale = Some(vec![x, y, z]);
                }
            }
            "eulerDegrees" => {
                if let WorldPropertyValue::Vec3(x, y, z) = value {
                    self.euler_degrees = Some(vec![x, y, z]);
                }
            }
            "parentRef" => {
                if let WorldPropertyValue::String(value) = value {
                    self.parent_ref = if value.is_empty() { None } else { Some(value) };
                }
            }
            "lightType" => {
                if let WorldPropertyValue::String(value) = value {
                    self.light_type = Some(value);
                }
            }
            "lightIntensity" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.light_intensity = Some(value);
                }
            }
            "lightColor" => {
                if let WorldPropertyValue::Vec3(r, g, b) = value {
                    self.light_color = Some(vec![r, g, b]);
                }
            }
            "lightRange" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.light_range = Some(value);
                }
            }
            "lightSpotInner" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.light_spot_inner = Some(value);
                }
            }
            "lightSpotOuter" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.light_spot_outer = Some(value);
                }
            }
            "lightCastShadows" => {
                if let WorldPropertyValue::Bool(value) = value {
                    self.light_cast_shadows = Some(value);
                }
            }
            "cameraFovYDegrees" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.camera_fov_y_degrees = Some(value);
                }
            }
            "cameraIsActive" => {
                if let WorldPropertyValue::Bool(value) = value {
                    self.camera_is_active = Some(value);
                }
            }
            "meshColor" => {
                if let WorldPropertyValue::Vec3(r, g, b) = value {
                    self.mesh_color = Some(vec![r, g, b]);
                }
            }
            "materialBaseColor" => {
                if let WorldPropertyValue::Vec4(r, g, b, a) = value {
                    self.material_base_color = Some(vec![r, g, b, a]);
                }
            }
            "materialMetallic" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.material_metallic = Some(value);
                }
            }
            "materialRoughness" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.material_roughness = Some(value);
                }
            }
            "materialEmissive" => {
                if let WorldPropertyValue::Vec3(r, g, b) = value {
                    self.material_emissive = Some(vec![r, g, b]);
                }
            }
            "rigidBodyMotionType" => {
                if let WorldPropertyValue::String(value) = value {
                    self.rigid_body_motion_type = Some(value);
                }
            }
            "rigidBodyMass" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.rigid_body_mass = Some(value);
                }
            }
            "rigidBodyGravityScale" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.rigid_body_gravity_scale = Some(value);
                }
            }
            "rigidBodyAllowSleep" => {
                if let WorldPropertyValue::Bool(value) = value {
                    self.rigid_body_allow_sleep = Some(value);
                }
            }
            "colliderShape" => {
                if let WorldPropertyValue::String(value) = value {
                    self.collider_shape = Some(value);
                    // Clear stale dimension fields when shape kind changes.
                    self.collider_box_half_extents = None;
                    self.collider_sphere_radius = None;
                    self.collider_capsule_radius = None;
                    self.collider_capsule_half_height = None;
                }
            }
            "colliderBoxHalfExtents" => {
                if let WorldPropertyValue::Vec3(x, y, z) = value {
                    self.collider_box_half_extents = Some(vec![x, y, z]);
                }
            }
            "colliderSphereRadius" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.collider_sphere_radius = Some(value);
                }
            }
            "colliderCapsuleRadius" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.collider_capsule_radius = Some(value);
                }
            }
            "colliderCapsuleHalfHeight" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.collider_capsule_half_height = Some(value);
                }
            }
            "colliderIsTrigger" => {
                if let WorldPropertyValue::Bool(value) = value {
                    self.collider_is_trigger = Some(value);
                }
            }
            "colliderFriction" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.collider_friction = Some(value);
                }
            }
            "colliderRestitution" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.collider_restitution = Some(value);
                }
            }
            "colliderDensity" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.collider_density = Some(value);
                }
            }
            "colliderLayerID" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.collider_layer_id = Some(value as i64);
                }
            }
            "colliderLayerMask" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.collider_layer_mask = Some(value as i64);
                }
            }
            "audioClip" => {
                if let WorldPropertyValue::String(value) = value {
                    self.audio_clip = Some(value);
                }
            }
            "audioVolume" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.audio_volume = Some(value);
                }
            }
            "audioLoop" => {
                if let WorldPropertyValue::Bool(value) = value {
                    self.audio_loop = Some(value);
                }
            }
            "audioPlayOnAwake" => {
                if let WorldPropertyValue::Bool(value) = value {
                    self.audio_play_on_awake = Some(value);
                }
            }
            "audioPitch" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.audio_pitch = Some(value);
                }
            }
            "audioSpatialBlend" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.audio_spatial_blend = Some(value);
                }
            }
            "meshIsVisible" => {
                if let WorldPropertyValue::Bool(value) = value {
                    self.mesh_is_visible = Some(value);
                }
            }
            "animationClip" => {
                if let WorldPropertyValue::String(value) = value {
                    self.animation_clip = if value.is_empty() { None } else { Some(value) };
                }
            }
            "animationSpeed" => {
                if let WorldPropertyValue::Float(value) = value {
                    self.animation_speed = Some(value);
                }
            }
            "animationLoop" => {
                if let WorldPropertyValue::Bool(value) = value {
                    self.animation_loop = Some(value);
                }
            }
            "animationIsPlaying" => {
                if let WorldPropertyValue::Bool(value) = value {
                    self.animation_is_playing = Some(value);
                }
            }
            "constraintEnabled" => {
                if let WorldPropertyValue::Bool(value) = value {
                    self.constraint_enabled = Some(value);
                }
            }
            "scriptBindings" => {
                if let WorldPropertyValue::String(json) = value
                    && let Some(records) = parse_script_bindings(&json)
                {
                    self.script_bindings = Some(records);
                }
            }
            _ => {}
        }
    }
}

/// Mirrors Swift's `JSONSerialization … as? [[String: Any]]` + `compactMap`:
/// a non-array payload (or an array containing a non-dictionary element)
/// leaves the existing bindings untouched, while malformed dictionaries inside
/// the array are dropped.
fn parse_script_bindings(json: &str) -> Option<Vec<SceneSemanticSnapshotScriptBindingRecord>> {
    let value: serde_json::Value = serde_json::from_str(json).ok()?;
    let items = value.as_array()?;
    let mut records = Vec::with_capacity(items.len());
    for item in items {
        let object = item.as_object()?;
        let handle = object.get("handle").and_then(|value| {
            value
                .as_u64()
                .or_else(|| value.as_i64().map(|signed| signed as u64))
        });
        let is_enabled = object.get("isEnabled").and_then(serde_json::Value::as_bool);
        let parameters_json = object
            .get("parametersJSON")
            .and_then(serde_json::Value::as_str);
        let (Some(handle), Some(is_enabled), Some(parameters_json)) =
            (handle, is_enabled, parameters_json)
        else {
            continue;
        };
        let identifier = object
            .get("identifier")
            .and_then(serde_json::Value::as_str)
            .map(str::to_string);
        records.push(SceneSemanticSnapshotScriptBindingRecord::new(
            handle,
            identifier,
            is_enabled,
            parameters_json.to_string(),
        ));
    }
    Some(records)
}

/// A brief record of one applied edit, kept in the recent-edit ring.
#[derive(Clone, Debug, PartialEq)]
pub struct WorldViewEdit {
    pub summary: String,
    pub revision: u64,
    pub timestamp: SwiftDate,
}

impl WorldViewEdit {
    pub fn new(summary: String, revision: u64) -> Self {
        Self {
            summary,
            revision,
            timestamp: SwiftDate::now(),
        }
    }

    pub fn with_timestamp(summary: String, revision: u64, timestamp: SwiftDate) -> Self {
        Self {
            summary,
            revision,
            timestamp,
        }
    }
}

/// Session's incrementally maintained understanding of the World.
///
/// Delta-driven: `WorldEvent`s update the entity index in O(1) per event.
/// `apply_snapshot` is the bootstrap path that seeds the index from a full scan.
#[derive(Clone, Debug)]
pub struct WorldView {
    /// Per-entity authored state, keyed by entity ref (`"scene:<id>"`).
    entity_index: BTreeMap<String, WorldEntityRecord>,
    pub scene_revision: Option<u64>,
    pub selected_entity_refs: Vec<String>,
    pub recent_edits: Vec<WorldViewEdit>,
    pub workflow_mode: Option<String>,
}

impl WorldView {
    const MAX_RECENT_EDITS: usize = 20;

    pub fn new() -> Self {
        Self {
            entity_index: BTreeMap::new(),
            scene_revision: None,
            selected_entity_refs: Vec::new(),
            recent_edits: Vec::new(),
            workflow_mode: None,
        }
    }

    pub fn entity_index(&self) -> &BTreeMap<String, WorldEntityRecord> {
        &self.entity_index
    }

    pub fn entity_record(&self, ref_: &str) -> Option<&WorldEntityRecord> {
        self.entity_index.get(ref_)
    }

    /// Applies a fine-grained `WorldEvent` to the entity index.
    pub fn apply_event(&mut self, event: WorldEvent) {
        match event {
            WorldEvent::EntityAdded { ref_, name, kind } => {
                let mut record = WorldEntityRecord::new(ref_.clone());
                record.name = name;
                record.kind = kind;
                record.is_selected = self.selected_entity_refs.contains(&ref_);
                self.entity_index.insert(ref_, record);
            }
            WorldEvent::EntityRemoved { ref_ } => {
                self.entity_index.remove(&ref_);
                self.selected_entity_refs
                    .retain(|selected| *selected != ref_);
            }
            WorldEvent::EntityAuthoredChanged {
                ref_,
                property,
                value,
            } => {
                self.entity_index
                    .entry(ref_.clone())
                    .or_insert_with(|| WorldEntityRecord::new(ref_))
                    .apply(property, value);
            }
            WorldEvent::EditApplied {
                summary, revision, ..
            } => {
                self.recent_edits
                    .push(WorldViewEdit::new(summary, revision));
                if self.recent_edits.len() > Self::MAX_RECENT_EDITS {
                    let excess = self.recent_edits.len() - Self::MAX_RECENT_EDITS;
                    self.recent_edits.drain(..excess);
                }
                self.scene_revision = Some(revision);
            }
            WorldEvent::SelectionChanged { refs } => {
                for record in self.entity_index.values_mut() {
                    record.is_selected = refs.contains(&record.ref_);
                }
                self.selected_entity_refs = refs;
            }
            WorldEvent::EntityEvaluatedChanged {
                ref_,
                property,
                value,
            } => {
                self.entity_index
                    .entry(ref_.clone())
                    .or_insert_with(|| WorldEntityRecord::new(ref_))
                    .evaluated
                    .insert(property, value);
            }
            WorldEvent::EntityInferredUpdated {
                ref_,
                property,
                value,
                confidence,
                source,
            } => {
                let record = self
                    .entity_index
                    .entry(ref_.clone())
                    .or_insert_with(|| WorldEntityRecord::new(ref_));
                record.inferred.insert(
                    property,
                    InferredProperty {
                        display_value: value.inferred_display_value(),
                        confidence,
                        source,
                    },
                );
            }
        }
    }

    /// Merges a `SceneSemanticSnapshot` into the entity index.
    ///
    /// Authoritative authored fields are overwritten from the snapshot.
    /// AI-inferred annotations and engine-computed evaluated values are
    /// preserved for entities that continue to exist. Entities absent from the
    /// new snapshot are removed.
    pub fn apply_snapshot(&mut self, snapshot: &SceneSemanticSnapshot) {
        let previous = std::mem::take(&mut self.entity_index);
        for entity in &snapshot.entities {
            let mut record = WorldEntityRecord::new(entity.id.clone());
            record.name = entity.name.clone();
            record.kind = Some(entity.kind.clone());
            if let Some(prev) = previous.get(&entity.id) {
                record.inferred = prev.inferred.clone();
                record.evaluated = prev.evaluated.clone();
            }
            record.parent_ref = entity.parent_ref.clone();
            record.child_refs = entity.child_refs.clone();
            record.components = entity.components.clone();
            record.is_selected = entity.is_selected;
            record.position = entity.position.clone();
            record.scale = entity.scale.clone();
            record.euler_degrees = entity.euler_degrees.clone();
            record.light_type = entity.light_type.clone();
            record.light_intensity = entity.light_intensity;
            record.light_color = entity.light_color.clone();
            record.light_range = entity.light_range;
            record.light_spot_inner = entity.light_spot_inner;
            record.light_spot_outer = entity.light_spot_outer;
            record.light_cast_shadows = entity.light_cast_shadows;
            record.camera_fov_y_degrees = entity.camera_fov_y_degrees;
            record.camera_is_active = entity.camera_is_active;
            record.mesh_color = entity.mesh_color.clone();
            record.material_base_color = entity.material_base_color.clone();
            record.material_metallic = entity.material_metallic;
            record.material_roughness = entity.material_roughness;
            record.material_emissive = entity.material_emissive.clone();
            record.rigid_body_motion_type = entity.rigid_body_motion_type.clone();
            record.rigid_body_mass = entity.rigid_body_mass;
            record.rigid_body_gravity_scale = entity.rigid_body_gravity_scale;
            record.rigid_body_allow_sleep = entity.rigid_body_allow_sleep;
            record.collider_shape = entity.collider_shape.clone();
            record.collider_box_half_extents = entity.collider_box_half_extents.clone();
            record.collider_sphere_radius = entity.collider_sphere_radius;
            record.collider_capsule_radius = entity.collider_capsule_radius;
            record.collider_capsule_half_height = entity.collider_capsule_half_height;
            record.collider_is_trigger = entity.collider_is_trigger;
            record.collider_friction = entity.collider_friction;
            record.collider_restitution = entity.collider_restitution;
            record.collider_density = entity.collider_density;
            record.collider_layer_id = entity.collider_layer_id;
            record.collider_layer_mask = entity.collider_layer_mask;
            record.audio_clip = entity.audio_clip.clone();
            record.audio_volume = entity.audio_volume;
            record.audio_loop = entity.audio_loop;
            record.audio_play_on_awake = entity.audio_play_on_awake;
            record.audio_pitch = entity.audio_pitch;
            record.audio_spatial_blend = entity.audio_spatial_blend;
            record.mesh_is_visible = entity.mesh_is_visible;
            record.animation_clip = entity.animation_clip.clone();
            record.animation_speed = entity.animation_speed;
            record.animation_loop = entity.animation_loop;
            record.animation_is_playing = entity.animation_is_playing;
            record.script_bindings = entity.script_bindings.clone();
            record.constraint_enabled = entity.constraint_enabled;
            record.ragdoll_mode = entity.ragdoll_mode.clone();
            record.ragdoll_blend_weight = entity.ragdoll_blend_weight;
            record.ragdoll_bone_count = entity.ragdoll_bone_count;
            record.ragdoll_simulated_bone_count = entity.ragdoll_simulated_bone_count;
            record.ragdoll_is_enabled = entity.ragdoll_is_enabled;
            if let Some(world_position) = &entity.world_position {
                record.evaluated.insert(
                    "worldPosition".to_string(),
                    WorldPropertyValue::Vec3(
                        world_position[0],
                        world_position[1],
                        world_position[2],
                    ),
                );
            }
            if let Some(world_euler) = &entity.world_euler_degrees {
                record.evaluated.insert(
                    "worldEulerDegrees".to_string(),
                    WorldPropertyValue::Vec3(world_euler[0], world_euler[1], world_euler[2]),
                );
            }
            if let Some(world_scale) = &entity.world_scale {
                record.evaluated.insert(
                    "worldScale".to_string(),
                    WorldPropertyValue::Vec3(world_scale[0], world_scale[1], world_scale[2]),
                );
            }
            self.entity_index.insert(entity.id.clone(), record);
        }
        self.scene_revision = Some(snapshot.scene_revision);
        self.workflow_mode = snapshot.workspace_mode.clone();
        self.selected_entity_refs = snapshot
            .entities
            .iter()
            .filter(|entity| entity.is_selected)
            .map(|entity| entity.id.clone())
            .collect();
    }

    /// Records an applied edit to the recent-edit ring without a full `WorldEvent`.
    pub fn apply_edit_summary(&mut self, edit_summary: String, revision: u64) {
        self.apply_event(WorldEvent::EditApplied {
            edit_id: String::new(),
            summary: edit_summary,
            revision,
        });
    }

    /// Updates the active selection without a `WorldEvent`.
    pub fn apply_selection_changed(&mut self, entity_refs: Vec<String>) {
        self.apply_event(WorldEvent::SelectionChanged { refs: entity_refs });
    }
}

impl Default for WorldView {
    fn default() -> Self {
        Self::new()
    }
}
