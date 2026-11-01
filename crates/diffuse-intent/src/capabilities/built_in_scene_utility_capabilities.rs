//! Scene creation, hierarchy, media and bounded script-parameter primitives.

use std::collections::BTreeMap;

use diffuse_capability::capsule_schema::{self, JsonSchema};
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::components::core::value::ComponentValue;
use diffuse_scene::components::editing::ComponentWriteMode;
use diffuse_scene::media::animation::AnimationPlayer;
use diffuse_script::core::script_component::{ScriptBinding, ScriptHandle};
use diffuse_script::interop::component_registry_script_codec::encode_script_binding_for_editing;
use serde::{Deserialize, Serialize, Serializer};

use super::built_in_typed_capabilities::{
    CapabilityLightType, capability_float, capability_vector, component_vector, prepared_entity_id,
    prepared_local_transform,
};
use super::cove_capability::{
    CapabilityPreparationError, CapabilityPreview, PreparedCapability, declare_capability,
};
use crate::invocation::capability_input_declaration::{
    CapabilitySchemaValue, SceneEntityRef, Vec3, entity_reference_schema, field_schema,
};
use crate::transactions::transaction_ir::{
    SceneMutation, TransactionOperation, TransactionVerificationAssertion,
};

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum SceneUtilityCapabilityPreparationError {
    #[error("entity '{0}' cannot be its own parent")]
    EntityCannotParentItself(String),
    #[error("script_property_name must not be empty")]
    EmptyScriptPropertyName,
    #[error("script binding {0} does not exist; provide script_identifier to create it")]
    MissingScriptBinding(i64),
    #[error("set_audio_source requires at least one audio field")]
    NoAudioFields,
    #[error("set_animation_player requires at least one animation field")]
    NoAnimationFields,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CapabilitySpawnKind {
    Mesh,
    Empty,
    Light,
    Camera,
}

impl CapabilitySpawnKind {
    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::Mesh => "mesh",
            Self::Empty => "empty",
            Self::Light => "light",
            Self::Camera => "camera",
        }
    }
}

impl CapabilitySchemaValue for CapabilitySpawnKind {
    fn capability_schema() -> JsonSchema {
        capsule_schema::string_enum(None, &["mesh", "empty", "light", "camera"])
    }
    fn capability_placeholder() -> Self {
        Self::Mesh
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(try_from = "serde_json::Value")]
pub enum CapabilityScriptScalar {
    String(String),
    Number(f64),
    Bool(bool),
}

impl TryFrom<serde_json::Value> for CapabilityScriptScalar {
    type Error = &'static str;
    fn try_from(value: serde_json::Value) -> Result<Self, Self::Error> {
        match value {
            serde_json::Value::Bool(value) => Ok(Self::Bool(value)),
            serde_json::Value::Number(value) => value
                .as_f64()
                .map(Self::Number)
                .ok_or("unsupported script scalar"),
            serde_json::Value::String(value) => Ok(Self::String(value)),
            _ => Err("unsupported script scalar"),
        }
    }
}

impl Serialize for CapabilityScriptScalar {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::String(v) => serializer.serialize_str(v),
            Self::Number(v) => serializer.serialize_f64(*v),
            Self::Bool(v) => serializer.serialize_bool(*v),
        }
    }
}

impl CapabilitySchemaValue for CapabilityScriptScalar {
    fn capability_schema() -> JsonSchema {
        capsule_schema::choice(vec![
            capsule_schema::string(None, None, None),
            capsule_schema::number(None, None, None),
            capsule_schema::boolean(),
        ])
    }
    fn capability_placeholder() -> Self {
        Self::String(String::new())
    }
}

impl CapabilityScriptScalar {
    fn component_value(&self) -> ComponentValue {
        match self {
            Self::String(v) => ComponentValue::String(v.clone()),
            Self::Number(v) => ComponentValue::Number(*v),
            Self::Bool(v) => ComponentValue::Bool(*v),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(try_from = "serde_json::Value")]
pub enum CapabilityScriptValue {
    String(String),
    Number(f64),
    Bool(bool),
    Array(Vec<CapabilityScriptScalar>),
}

impl TryFrom<serde_json::Value> for CapabilityScriptValue {
    type Error = &'static str;
    fn try_from(value: serde_json::Value) -> Result<Self, Self::Error> {
        match value {
            serde_json::Value::Bool(value) => Ok(Self::Bool(value)),
            serde_json::Value::Number(value) => value
                .as_f64()
                .map(Self::Number)
                .ok_or("unsupported script value"),
            serde_json::Value::String(value) => Ok(Self::String(value)),
            serde_json::Value::Array(values) => values
                .into_iter()
                .map(CapabilityScriptScalar::try_from)
                .collect::<Result<Vec<_>, _>>()
                .map(Self::Array)
                .map_err(|_| "unsupported script value"),
            _ => Err("unsupported script value"),
        }
    }
}

impl Serialize for CapabilityScriptValue {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::String(v) => serializer.serialize_str(v),
            Self::Number(v) => serializer.serialize_f64(*v),
            Self::Bool(v) => serializer.serialize_bool(*v),
            Self::Array(v) => v.serialize(serializer),
        }
    }
}

impl CapabilitySchemaValue for CapabilityScriptValue {
    fn capability_schema() -> JsonSchema {
        capsule_schema::choice(vec![
            capsule_schema::string(None, None, None),
            capsule_schema::number(None, None, None),
            capsule_schema::boolean(),
            capsule_schema::array(
                CapabilityScriptScalar::capability_schema(),
                None,
                None,
                Some(256),
            ),
        ])
    }
    fn capability_placeholder() -> Self {
        Self::String(String::new())
    }
}

impl CapabilityScriptValue {
    fn component_value(&self) -> ComponentValue {
        match self {
            Self::String(v) => ComponentValue::String(v.clone()),
            Self::Number(v) => ComponentValue::Number(*v),
            Self::Bool(v) => ComponentValue::Bool(*v),
            Self::Array(v) => ComponentValue::Array(
                v.iter()
                    .map(CapabilityScriptScalar::component_value)
                    .collect(),
            ),
        }
    }
}

fn prepared_single(
    entity_id: u64,
    reference: &SceneEntityRef,
    summary: &str,
    mutation: SceneMutation,
) -> PreparedCapability {
    PreparedCapability::new(
        vec![TransactionOperation::Scene(mutation)],
        CapabilityPreview::new(summary, vec![reference.as_str().to_string()]),
        vec![TransactionVerificationAssertion::EntityExists(entity_id)],
    )
}

fn merge_script_property(
    json: &str,
    name: String,
    value: CapabilityScriptValue,
) -> Result<String, CapabilityPreparationError> {
    let mut object =
        serde_json::from_str::<BTreeMap<String, ComponentValue>>(json).unwrap_or_default();
    object.insert(name, value.component_value());
    Ok(diffuse_assets::swift_json::to_compact(&object)?)
}

fn script_mutation(entity_id: u64, bindings: &[ScriptBinding]) -> SceneMutation {
    SceneMutation::SetComponentData {
        entity_id,
        type_id: "script".to_string(),
        value: ComponentValue::Object(BTreeMap::from([(
            "bindings".to_string(),
            ComponentValue::Array(
                bindings
                    .iter()
                    .map(|b| ComponentValue::Object(encode_script_binding_for_editing(b)))
                    .collect(),
            ),
        )])),
        mode: ComponentWriteMode::Replace,
    }
}

declare_capability! {
    SpawnEntityCapability, SpawnEntityInput,
    "scene.spawn_entity", "Spawn entity", "Create a mesh, empty, light, or camera entity.", ReversibleWrite, Stable,
    {
        label: Option<String> => field_schema::<Option<String>>(Some("Entity display name."), None, None, Some(1), Some(256), None),
        spawn_position: Option<Vec3> => field_schema::<Option<Vec3>>(Some("Initial local-space position."), None, None, None, None, None),
        spawn_kind: Option<CapabilitySpawnKind> => field_schema::<Option<CapabilitySpawnKind>>(Some("Kind of entity to create."), None, None, None, None, None),
        spawn_parent_id: Option<SceneEntityRef> => field_schema::<Option<SceneEntityRef>>(Some("Optional existing parent entity."), None, None, None, None, None),
        light_type: Option<CapabilityLightType> => field_schema::<Option<CapabilityLightType>>(Some("Initial type when spawning a light."), None, None, None, None, None),
        intensity: Option<f64> => field_schema::<Option<f64>>(None, Some(0.0), None, None, None, None),
        color: Option<Vec3> => field_schema::<Option<Vec3>>(None, Some(0.0), Some(1.0), None, None, None),
        range: Option<f64> => field_schema::<Option<f64>>(None, Some(0.0), None, None, None, None),
        light_cast_shadows: Option<bool> => field_schema::<Option<bool>>(Some("Initial shadow state when spawning a light."), None, None, None, None, None),
        camera_fov_y: Option<f64> => field_schema::<Option<f64>>(None, Some(1.0), Some(179.0), None, None, None)
    },
    |input, context| {
        let label = input.label.unwrap_or_else(|| "AI Entity".to_string());
        let position = input
            .spawn_position
            .map(|v| capability_vector(v, "spawn_position"))
            .transpose()?
            .unwrap_or(Float3::ZERO);
        let parent_id = input
            .spawn_parent_id
            .as_ref()
            .map(|v| prepared_entity_id(v, None, context))
            .transpose()?;
        let kind = input.spawn_kind.unwrap_or(CapabilitySpawnKind::Mesh);
        let mutation = match kind {
            CapabilitySpawnKind::Mesh => SceneMutation::SpawnImportedMeshEntity {
                label,
                kind_label: "Static Mesh".to_string(),
                mesh_index: 0,
                position,
                parent_id,
            },
            CapabilitySpawnKind::Empty => SceneMutation::SpawnEmptyEntity {
                label,
                position,
                parent_id,
            },
            CapabilitySpawnKind::Light => SceneMutation::SpawnLightEntity {
                label,
                light_type: input
                    .light_type
                    .unwrap_or(CapabilityLightType::Point)
                    .runtime_value(),
                position,
                initial_intensity: input
                    .intensity
                    .map(|v| capability_float(v, "intensity"))
                    .transpose()?,
                initial_color: input
                    .color
                    .map(|v| capability_vector(v, "color"))
                    .transpose()?,
                initial_range: input
                    .range
                    .map(|v| capability_float(v, "range"))
                    .transpose()?,
                initial_cast_shadows: input.light_cast_shadows,
                parent_id,
            },
            CapabilitySpawnKind::Camera => SceneMutation::SpawnCameraEntity {
                label,
                position,
                initial_fov_y_degrees: input
                    .camera_fov_y
                    .map(|v| capability_float(v, "camera_fov_y"))
                    .transpose()?,
                parent_id,
            },
        };
        Ok(PreparedCapability::new(
            vec![TransactionOperation::Scene(mutation)],
            CapabilityPreview::new(
                format!("Spawn {} entity", kind.raw_value()),
                input
                    .spawn_parent_id
                    .map(|v| vec![v.as_str().to_string()])
                    .unwrap_or_default(),
            ),
            vec![TransactionVerificationAssertion::SceneRevisionAdvanced {
                from: context.scene_revision,
            }],
        ))
    }
}

declare_capability! {
    ReparentEntityCapability, ReparentEntityInput,
    "scene.reparent_entity", "Reparent entity", "Move an entity beneath another entity or to the scene root.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        parent_id: Option<SceneEntityRef> => field_schema::<Option<SceneEntityRef>>(Some("New parent entity. Omit to move to the scene root."), None, None, None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, None, context)?;
        if input.parent_id.as_ref() == Some(&input.entity_id) {
            return Err(
                SceneUtilityCapabilityPreparationError::EntityCannotParentItself(
                    input.entity_id.as_str().to_string(),
                )
                .into(),
            );
        }
        let parent_id = input
            .parent_id
            .as_ref()
            .map(|v| prepared_entity_id(v, None, context))
            .transpose()?;
        let mut targets = vec![input.entity_id.as_str().to_string()];
        if let Some(parent) = input.parent_id {
            targets.push(parent.as_str().to_string());
        }
        Ok(PreparedCapability::new(
            vec![TransactionOperation::Scene(SceneMutation::MoveEntity {
                entity_id: id,
                parent_id,
                index: i64::MAX,
            })],
            CapabilityPreview::new("Reparent entity", targets),
            vec![TransactionVerificationAssertion::EntityExists(id)],
        ))
    }
}

declare_capability! {
    SnapToGroundCapability, SnapToGroundInput,
    "scene.snap_to_ground", "Snap to ground", "Move an entity to the ground plane at y=0.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["LocalTransform"])
    },
    |input, context| {
        let (id, mut transform) = prepared_local_transform(&input.entity_id, context)?;
        transform.matrix.columns[3].y = 0.0;
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Snap entity to ground",
            SceneMutation::SetLocalTransform {
                entity_id: id,
                transform,
            },
        ))
    }
}

declare_capability! {
    SetMeshColorCapability, SetMeshColorInput,
    "scene.set_mesh_color", "Set mesh colour", "Set the linear RGB colour tint of a render mesh.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["RenderMeshComponent"]),
        color: Vec3 => field_schema::<Vec3>(None, Some(0.0), Some(1.0), None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, Some("RenderMeshComponent"), context)?;
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set mesh colour",
            SceneMutation::component_fields(
                id,
                "renderMesh",
                [(
                    "colorTint".to_string(),
                    Some(component_vector(capability_vector(input.color, "color")?)),
                )],
            ),
        ))
    }
}

declare_capability! {
    SetMeshVisibilityCapability, SetMeshVisibilityInput,
    "scene.set_mesh_visibility", "Set mesh visibility", "Show or hide a render mesh.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["RenderMeshComponent"]),
        is_visible: bool => field_schema::<bool>(Some("Whether the render mesh is visible."), None, None, None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, Some("RenderMeshComponent"), context)?;
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set mesh visibility",
            SceneMutation::component_fields(
                id,
                "renderMesh",
                [(
                    "isVisible".to_string(),
                    Some(ComponentValue::Bool(input.is_visible)),
                )],
            ),
        ))
    }
}

declare_capability! {
    SetConstraintEnabledCapability, SetConstraintEnabledInput,
    "scene.set_constraint_enabled", "Set constraint enabled", "Enable or disable a physics constraint.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&["PhysicsJoint"]),
        is_enabled: bool => field_schema::<bool>(Some("Whether the constraint is enabled."), None, None, None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, Some("PhysicsJoint"), context)?;
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set constraint enabled",
            SceneMutation::component_fields(
                id,
                "constraint",
                [(
                    "isEnabled".to_string(),
                    Some(ComponentValue::Bool(input.is_enabled)),
                )],
            ),
        ))
    }
}

declare_capability! {
    SetAudioSourceCapability, SetAudioSourceInput,
    "scene.set_audio_source", "Set audio source", "Configure an entity's audio source.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        audio_clip: Option<String> => field_schema::<Option<String>>(Some("Audio clip asset name."), None, None, None, Some(1_024), None),
        audio_volume: Option<f64> => field_schema::<Option<f64>>(None, Some(0.0), Some(1.0), None, None, None),
        audio_pitch: Option<f64> => field_schema::<Option<f64>>(None, Some(0.01), Some(4.0), None, None, None),
        audio_loop: Option<bool> => field_schema::<Option<bool>>(Some("Whether playback loops."), None, None, None, None, None),
        audio_play_on_awake: Option<bool> => field_schema::<Option<bool>>(Some("Whether playback starts when play mode begins."), None, None, None, None, None),
        audio_spatial_blend: Option<f64> => field_schema::<Option<f64>>(None, Some(0.0), Some(1.0), None, None, None)
    },
    |input, context| {
        if input.audio_clip.is_none()
            && input.audio_volume.is_none()
            && input.audio_pitch.is_none()
            && input.audio_loop.is_none()
            && input.audio_play_on_awake.is_none()
            && input.audio_spatial_blend.is_none()
        {
            return Err(SceneUtilityCapabilityPreparationError::NoAudioFields.into());
        }
        let id = prepared_entity_id(&input.entity_id, None, context)?;
        let mut source = context
            .entities
            .iter()
            .find(|e| e.reference == input.entity_id.as_str())
            .and_then(|e| e.audio_source.clone())
            .unwrap_or_default();
        if let Some(value) = input.audio_clip {
            source.clip_name = value;
        }
        if let Some(value) = input.audio_volume {
            source.volume = capability_float(value, "audio_volume")?;
        }
        if let Some(value) = input.audio_pitch {
            source.pitch = capability_float(value, "audio_pitch")?;
        }
        if let Some(value) = input.audio_loop {
            source.loop_ = value;
        }
        if let Some(value) = input.audio_play_on_awake {
            source.play_on_awake = value;
        }
        if let Some(value) = input.audio_spatial_blend {
            source.spatial_blend = capability_float(value, "audio_spatial_blend")?;
        }
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set audio source",
            SceneMutation::component_data(id, "audioSource", source, ComponentRegistry::built_in()),
        ))
    }
}

declare_capability! {
    SetScriptPropertyCapability, SetScriptPropertyInput,
    "scene.set_script_property", "Set script property", "Set one bounded script parameter value.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        script_index: Option<i64> => field_schema::<Option<i64>>(None, Some(0.0), Some(255.0), None, None, None),
        script_identifier: Option<String> => field_schema::<Option<String>>(Some("Stable script catalog id. Provide it to create or replace a binding."), None, None, Some(1), Some(256), None),
        script_property_name: String => field_schema::<String>(Some("Script property name."), None, None, Some(1), Some(256), None),
        script_property_value: CapabilityScriptValue => field_schema::<CapabilityScriptValue>(Some("Bounded string, number, boolean, or scalar array value."), None, None, None, None, None)
    },
    |input, context| {
        if input.script_property_name.is_empty() {
            return Err(SceneUtilityCapabilityPreparationError::EmptyScriptPropertyName.into());
        }
        let id = prepared_entity_id(&input.entity_id, None, context)?;
        let index = input.script_index.unwrap_or(0);
        let mut bindings = context
            .entities
            .iter()
            .find(|e| e.reference == input.entity_id.as_str())
            .map(|e| e.script_bindings.clone())
            .unwrap_or_default();
        if index > bindings.len() as i64 {
            return Err(SceneUtilityCapabilityPreparationError::MissingScriptBinding(index).into());
        }
        if index == bindings.len() as i64 {
            let identifier = input
                .script_identifier
                .ok_or(SceneUtilityCapabilityPreparationError::MissingScriptBinding(index))?;
            bindings.push(ScriptBinding::with_identifier(identifier));
        } else if let Some(identifier) = input.script_identifier {
            let binding =
                &mut bindings[usize::try_from(index).expect("script binding index cannot be negative")];
            binding.identifier = Some(identifier);
            binding.script = ScriptHandle::new(0);
        }
        let offset = usize::try_from(index).expect("script binding index cannot be negative");
        bindings[offset].parameters_json = merge_script_property(
            &bindings[offset].parameters_json,
            input.script_property_name,
            input.script_property_value,
        )?;
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set script property",
            script_mutation(id, &bindings),
        ))
    }
}

declare_capability! {
    SetScriptBindingsCapability, SetScriptBindingsInput,
    "scene.set_script_bindings", "Set script binding", "Create, replace, enable, or disable a stable script binding.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        script_index: Option<i64> => field_schema::<Option<i64>>(None, Some(0.0), Some(255.0), None, None, None),
        script_identifier: Option<String> => field_schema::<Option<String>>(Some("Stable script catalog id. Provide it to create or replace a binding."), None, None, Some(1), Some(256), None),
        is_enabled: bool => field_schema::<bool>(Some("Whether the selected script binding is enabled."), None, None, None, None, None)
    },
    |input, context| {
        let id = prepared_entity_id(&input.entity_id, None, context)?;
        let index = input.script_index.unwrap_or(0);
        let mut bindings = context
            .entities
            .iter()
            .find(|e| e.reference == input.entity_id.as_str())
            .map(|e| e.script_bindings.clone())
            .unwrap_or_default();
        if index > bindings.len() as i64 {
            return Err(SceneUtilityCapabilityPreparationError::MissingScriptBinding(index).into());
        }
        if index == bindings.len() as i64 {
            let identifier = input
                .script_identifier
                .ok_or(SceneUtilityCapabilityPreparationError::MissingScriptBinding(index))?;
            let mut binding = ScriptBinding::with_identifier(identifier);
            binding.is_enabled = input.is_enabled;
            bindings.push(binding);
        } else {
            let binding =
                &mut bindings[usize::try_from(index).expect("script binding index cannot be negative")];
            if let Some(identifier) = input.script_identifier {
                binding.identifier = Some(identifier);
                binding.script = ScriptHandle::new(0);
            }
            binding.is_enabled = input.is_enabled;
        }
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set script binding",
            script_mutation(id, &bindings),
        ))
    }
}

declare_capability! {
    SetAnimationPlayerCapability, SetAnimationPlayerInput,
    "scene.set_animation_player", "Set animation player", "Configure animation clip playback.", ReversibleWrite, Stable,
    {
        entity_id: SceneEntityRef => entity_reference_schema(&[]),
        animation_clip: Option<String> => field_schema::<Option<String>>(Some("Animation clip name; an empty string selects the default clip."), None, None, None, Some(1_024), None),
        animation_speed: Option<f64> => field_schema::<Option<f64>>(None, Some(0.0), None, None, None, None),
        animation_loop: Option<bool> => field_schema::<Option<bool>>(Some("Whether playback loops."), None, None, None, None, None),
        animation_is_playing: Option<bool> => field_schema::<Option<bool>>(Some("Whether playback is running."), None, None, None, None, None)
    },
    |input, context| {
        if input.animation_clip.is_none()
            && input.animation_speed.is_none()
            && input.animation_loop.is_none()
            && input.animation_is_playing.is_none()
        {
            return Err(SceneUtilityCapabilityPreparationError::NoAnimationFields.into());
        }
        let id = prepared_entity_id(&input.entity_id, None, context)?;
        let mut player = context
            .entities
            .iter()
            .find(|e| e.reference == input.entity_id.as_str())
            .and_then(|e| e.animation_player.clone())
            .unwrap_or_default();
        if let Some(value) = input.animation_clip {
            player.clip_name = if value.is_empty() { None } else { Some(value) };
        }
        if let Some(value) = input.animation_speed {
            player.speed = capability_float(value, "animation_speed")?;
        }
        if let Some(value) = input.animation_loop {
            player.loop_ = value;
        }
        if let Some(value) = input.animation_is_playing {
            player.is_playing = value;
        }
        let component = AnimationPlayer::new(
            player.clip_name,
            player.speed,
            player.loop_,
            player.is_playing,
            0.0,
        );
        Ok(prepared_single(
            id,
            &input.entity_id,
            "Set animation player",
            SceneMutation::component_data(
                id,
                "animationPlayer",
                component,
                ComponentRegistry::built_in(),
            ),
        ))
    }
}
