//! `SceneSerializer` — the relocatable scene/prefab document format (version 3).
//!
//! MIGRATION.md §5.4: the bytes must match Swift's
//! `JSONSerialization.data(withJSONObject:options: [.prettyPrinted, .sortedKeys])`.
//! That means two-space indent, `" : "` between key and value, keys sorted by
//! UTF-8 code unit, and empty containers written as a blank line between the
//! brackets. `swift_json` in `diffuse-assets` implements the same layout, but
//! `diffuse-scene` must not depend on `diffuse-assets` (the dependency runs the
//! other way), so the writer lives here.
//!
//! Entity cross-references are stored as **indices** into the document's entity
//! array, never as `EntityID`s, so a captured subtree is relocatable.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::components::core::registry::{
    ComponentDecodeContext, ComponentEncodeContext, ComponentEncodePurpose,
};
use crate::components::core::value::{ComponentValue, ManifestComponent};
use crate::entity_id::EntityID;
use crate::runtime_world::{LocalTransform, RuntimeWorld};
use crate::scene_bootstrap::{SceneKindComponent, SceneNameComponent};

/// The document version stamped into scenes and prefabs.
pub const SCENE_DOCUMENT_VERSION: i64 = 3;
/// Prefabs share the scene format.
pub const PREFAB_VERSION: i64 = SCENE_DOCUMENT_VERSION;

#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum SceneSerializerError {
    #[error("invalid scene document")]
    InvalidFormat,
    #[error("unsupported scene document version: {0}")]
    UnsupportedVersion(i64),
}

/// One entity as it appears in the document.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct EntityDocument {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent: Option<i64>,
    /// Decomposed transform: written as three arrays rather than a matrix so a
    /// hand-authored document stays readable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub translation: Option<Vec<f32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rotation: Option<Vec<f32>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scale: Option<Vec<f32>>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty", default)]
    pub components: BTreeMap<String, serde_json::Value>,
}

/// The whole document.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SceneDocument {
    pub version: i64,
    pub entities: Vec<EntityDocument>,
}

pub enum SceneSerializer {}

impl SceneSerializer {
    // MARK: - Save

    /// Serialize the authored scene.
    pub fn serialize(world: &RuntimeWorld) -> Result<String, SceneSerializerError> {
        Self::serialize_with_purpose(world, ComponentEncodePurpose::Authored)
    }

    /// Serialize for a game save: keeps destruction fragments, which the authored
    /// document drops.
    pub fn serialize_game_state(world: &RuntimeWorld) -> Result<String, SceneSerializerError> {
        Self::serialize_with_purpose(world, ComponentEncodePurpose::GameSave)
    }

    fn serialize_with_purpose(
        world: &RuntimeWorld,
        purpose: ComponentEncodePurpose,
    ) -> Result<String, SceneSerializerError> {
        let entities: Vec<EntityID> = world
            .entities()
            .into_iter()
            .filter(|entity| {
                purpose == ComponentEncodePurpose::GameSave
                    || !is_destruction_fragment(world, *entity)
            })
            .collect();

        let entity_index_map: BTreeMap<EntityID, i64> = entities
            .iter()
            .enumerate()
            .map(|(index, entity)| (*entity, index as i64))
            .collect();

        let document = SceneDocument {
            version: SCENE_DOCUMENT_VERSION,
            entities: entities
                .iter()
                .map(|entity| Self::encode_entity(world, *entity, &entity_index_map, purpose))
                .collect(),
        };
        Ok(to_sorted_pretty(&document))
    }

    /// Encode one entity. All cross-references become document indices; a reference
    /// to an entity outside `entity_index_map` is dropped, which is what makes a
    /// captured prefab subtree self-contained.
    pub fn encode_entity(
        world: &RuntimeWorld,
        entity: EntityID,
        entity_index_map: &BTreeMap<EntityID, i64>,
        purpose: ComponentEncodePurpose,
    ) -> EntityDocument {
        let mut document = EntityDocument::default();

        if let Some(name) = world.component::<SceneNameComponent>(entity) {
            document.name = Some(name.value.clone());
        }
        if let Some(kind) = world.component::<SceneKindComponent>(entity) {
            document.kind = Some(kind.value.clone());
        }
        if let Some(parent) = world.parent(entity)
            && let Some(index) = entity_index_map.get(&parent)
        {
            document.parent = Some(*index);
        }

        if let Some(transform) = world.local_transform(entity) {
            let (translation, rotation, scale) = decompose_transform(&transform);
            document.translation = Some(translation);
            document.rotation = Some(rotation);
            document.scale = Some(scale);
        }

        let mut context = ComponentEncodeContext::new(entity_index_map.clone());
        context.purpose = purpose;
        let components = world.component_registry.encode(entity, world, &mut context);
        let mut encoded: BTreeMap<String, serde_json::Value> = components
            .into_iter()
            .map(|component| (component.type_id.clone(), component.value.to_json_value()))
            .collect();

        // Swift `SceneSerializer.encodeEntity`: an authored document drops
        // runtime destruction fragments, while a game save keeps the sources,
        // live fragments and retained proxies as three extra component records.
        if purpose == ComponentEncodePurpose::GameSave {
            let runtime =
                world.resource::<crate::physics::destruction::DestructionRuntimeStateResource>();
            if let Some(source) = runtime
                .as_ref()
                .and_then(|runtime| runtime.sources.get(&entity))
            {
                encoded.insert(
                    "destructionRuntimeSource".to_string(),
                    ComponentValue::Object(Self::serialize_destruction_runtime_source(source))
                        .to_json_value(),
                );
            }
            if let Some(fragment) =
                world.component::<crate::physics::destruction::DestructibleFragment>(entity)
                && let Some(&source_index) = entity_index_map.get(&fragment.source_entity)
            {
                encoded.insert(
                    "destructibleFragment".to_string(),
                    ComponentValue::Object(Self::serialize_destructible_fragment(
                        &fragment,
                        source_index,
                        entity,
                        runtime.as_ref(),
                    ))
                    .to_json_value(),
                );
            }
            if let Some(retained) =
                world.component::<crate::physics::destruction::DestructibleRetainedFragment>(entity)
                && let Some(&source_index) = entity_index_map.get(&retained.source_entity)
            {
                encoded.insert(
                    "destructibleRetainedFragment".to_string(),
                    serde_json::json!({
                        "sourceEntity": source_index,
                        "fragmentID": retained.fragment_id,
                    }),
                );
            }
        }
        document.components = encoded;

        document
    }

    /// The component representation shared by runtime and editor documents.
    pub fn component_document(
        world: &RuntimeWorld,
        entity: EntityID,
        context: &mut ComponentEncodeContext,
    ) -> Vec<ManifestComponent> {
        world.component_registry.encode(entity, world, context)
    }

    /// Apply a component document onto an existing entity.
    pub fn apply_component_document(
        world: &mut RuntimeWorld,
        entity: EntityID,
        components: &[ManifestComponent],
        context: &mut ComponentDecodeContext,
    ) {
        let registry = world.component_registry.clone();
        registry.decode(components, entity, context, world);
    }

    // MARK: - Load

    /// Deserialize authored entities into `world`, returning them in document order.
    pub fn deserialize(
        text: &str,
        world: &mut RuntimeWorld,
    ) -> Result<Vec<EntityID>, SceneSerializerError> {
        Self::deserialize_with_purpose(text, world, false)
    }

    /// Deserialize a game save, restoring destruction runtime state.
    pub fn deserialize_game_state(
        text: &str,
        world: &mut RuntimeWorld,
    ) -> Result<Vec<EntityID>, SceneSerializerError> {
        Self::deserialize_with_purpose(text, world, true)
    }

    fn deserialize_with_purpose(
        text: &str,
        world: &mut RuntimeWorld,
        restore_game_state: bool,
    ) -> Result<Vec<EntityID>, SceneSerializerError> {
        let value: serde_json::Value =
            serde_json::from_str(text).map_err(|_| SceneSerializerError::InvalidFormat)?;
        let version = value
            .get("version")
            .and_then(serde_json::Value::as_i64)
            .unwrap_or(0);
        // Reject a partially decoded entity array rather than compacting it: indices
        // are load-bearing for parents, constraints, ragdolls and fragment sources.
        let entities = value
            .get("entities")
            .and_then(serde_json::Value::as_array)
            .ok_or(SceneSerializerError::InvalidFormat)?;
        if !entities.iter().all(serde_json::Value::is_object) {
            return Err(SceneSerializerError::InvalidFormat);
        }
        if version != SCENE_DOCUMENT_VERSION {
            return Err(SceneSerializerError::UnsupportedVersion(version));
        }
        Ok(Self::load_entities(entities, world, restore_game_state))
    }

    /// Create every entity first, then decode components, then wire parents.
    ///
    /// Allocating the whole map up front lets any codec resolve a forward reference
    /// without component-specific deferred passes.
    pub fn load_entities(
        entities: &[serde_json::Value],
        world: &mut RuntimeWorld,
        restore_game_state: bool,
    ) -> Vec<EntityID> {
        let mut entity_map: BTreeMap<i64, EntityID> = BTreeMap::new();
        for (index, value) in entities.iter().enumerate() {
            if value.is_object() {
                entity_map.insert(index as i64, world.create_entity());
            }
        }
        let registry = world.component_registry.clone();
        let mut context = ComponentDecodeContext::new(entity_map.clone());

        for (index, value) in entities.iter().enumerate() {
            let Some(&entity) = entity_map.get(&(index as i64)) else {
                continue;
            };
            let Some(object) = value.as_object() else {
                continue;
            };
            Self::decode_entity_structure(object, entity, world);

            let components: Vec<ManifestComponent> = object
                .get("components")
                .and_then(serde_json::Value::as_object)
                .map(|components| {
                    components
                        .iter()
                        .map(|(type_id, value)| {
                            ManifestComponent::new(
                                type_id.clone(),
                                ComponentValue::from_json_value(value),
                            )
                        })
                        .collect()
                })
                .unwrap_or_default();
            registry.decode(&components, entity, &mut context, world);
        }

        // Parents are wired last: a child may precede its parent in document order.
        for (index, value) in entities.iter().enumerate() {
            let Some(&entity) = entity_map.get(&(index as i64)) else {
                continue;
            };
            let Some(object) = value.as_object() else {
                continue;
            };
            let Some(parent_index) = object.get("parent").and_then(serde_json::Value::as_i64)
            else {
                continue;
            };
            let Some(&parent) = entity_map.get(&parent_index) else {
                continue;
            };
            world.set_parent(Some(parent), entity);
        }

        if restore_game_state {
            Self::restore_destruction_runtime_state(entities, &entity_map, world);
        }

        entities
            .iter()
            .enumerate()
            .filter_map(|(index, _)| entity_map.get(&(index as i64)).copied())
            .collect()
    }

    fn decode_entity_structure(
        object: &serde_json::Map<String, serde_json::Value>,
        entity: EntityID,
        world: &mut RuntimeWorld,
    ) {
        if let Some(name) = object.get("name").and_then(serde_json::Value::as_str) {
            world.set_component(SceneNameComponent::new(name), entity);
        }
        if let Some(kind) = object.get("kind").and_then(serde_json::Value::as_str) {
            world.set_component(SceneKindComponent::new(kind), entity);
        }

        let translation =
            float_array(object.get("translation")).unwrap_or_else(|| vec![0.0, 0.0, 0.0]);
        let rotation =
            float_array(object.get("rotation")).unwrap_or_else(|| vec![0.0, 0.0, 0.0, 1.0]);
        let scale = float_array(object.get("scale")).unwrap_or_else(|| vec![1.0, 1.0, 1.0]);

        use diffuse_math::simd::simd_compat::{Float4, Float4x4, Quatf};
        let quaternion = Quatf::from_vector(Float4::new(
            rotation.first().copied().unwrap_or(0.0),
            rotation.get(1).copied().unwrap_or(0.0),
            rotation.get(2).copied().unwrap_or(0.0),
            rotation.get(3).copied().unwrap_or(1.0),
        ));
        let mut matrix = Float4x4::from_quatf(quaternion)
            * Float4x4::diagonal(Float4::new(
                scale.first().copied().unwrap_or(1.0),
                scale.get(1).copied().unwrap_or(1.0),
                scale.get(2).copied().unwrap_or(1.0),
                1.0,
            ));
        matrix.set_column(
            3,
            Float4::new(
                translation.first().copied().unwrap_or(0.0),
                translation.get(1).copied().unwrap_or(0.0),
                translation.get(2).copied().unwrap_or(0.0),
                1.0,
            ),
        );
        world.set_local_transform(LocalTransform::new(matrix), entity);
    }
}

/// Authored documents drop runtime destruction fragments.
fn is_destruction_fragment(world: &RuntimeWorld, entity: EntityID) -> bool {
    world
        .component::<crate::physics::destruction::DestructibleFragment>(entity)
        .is_some()
        || world
            .component::<crate::physics::destruction::DestructibleRetainedFragment>(entity)
            .is_some()
}

/// Split a `LocalTransform` matrix into translation, quaternion and scale.
///
/// A zero-length basis column is divided by 1 rather than normalised away, matching
/// Swift (and `LocalTransform::rotation()`); using `normalize()` here would produce
/// NaN for zero scale.
fn decompose_transform(transform: &LocalTransform) -> (Vec<f32>, Vec<f32>, Vec<f32>) {
    use diffuse_math::simd::simd_compat::{Float3, Float3x3, Quatf, simd_length};

    let matrix = transform.matrix;
    let translation = matrix.columns[3];
    let c0 = Float3::new(
        matrix.columns[0].x,
        matrix.columns[0].y,
        matrix.columns[0].z,
    );
    let c1 = Float3::new(
        matrix.columns[1].x,
        matrix.columns[1].y,
        matrix.columns[1].z,
    );
    let c2 = Float3::new(
        matrix.columns[2].x,
        matrix.columns[2].y,
        matrix.columns[2].z,
    );
    let sx = simd_length(c0);
    let sy = simd_length(c1);
    let sz = simd_length(c2);
    let basis = Float3x3::from_columns([
        c0 / if sx > 1e-6 { sx } else { 1.0 },
        c1 / if sy > 1e-6 { sy } else { 1.0 },
        c2 / if sz > 1e-6 { sz } else { 1.0 },
    ]);
    let quaternion = Quatf::from_float3x3(basis);
    (
        vec![translation.x, translation.y, translation.z],
        vec![
            quaternion.vector.x,
            quaternion.vector.y,
            quaternion.vector.z,
            quaternion.vector.w,
        ],
        vec![sx, sy, sz],
    )
}

fn float_array(value: Option<&serde_json::Value>) -> Option<Vec<f32>> {
    value.and_then(serde_json::Value::as_array).map(|values| {
        values
            .iter()
            .filter_map(|value| value.as_f64().map(|v| v as f32))
            .collect()
    })
}

// MARK: - Swift `JSONSerialization(.prettyPrinted, .sortedKeys)` writer

/// Writes `value` exactly as Swift's pretty/sorted `JSONSerialization` does.
///
/// Verified against Swift 6.4.1: two-space indent, `" : "` before a value, keys in
/// UTF-8 code-unit order, and an empty object/array rendered as a blank line
/// between its brackets.
pub fn to_sorted_pretty<T: Serialize + ?Sized>(value: &T) -> String {
    let json = serde_json::to_value(value).unwrap_or(serde_json::Value::Null);
    let mut out = String::new();
    write_value(&json, 0, &mut out);
    out
}

fn write_indent(depth: usize, out: &mut String) {
    for _ in 0..depth {
        out.push_str("  ");
    }
}

fn write_value(value: &serde_json::Value, depth: usize, out: &mut String) {
    match value {
        serde_json::Value::Object(map) => {
            if map.is_empty() {
                out.push_str("{\n\n");
                write_indent(depth, out);
                out.push('}');
                return;
            }
            out.push_str("{\n");
            let mut entries: Vec<(&String, &serde_json::Value)> = map.iter().collect();
            // `serde_json::Map` already sorts, but be explicit: the contract is
            // UTF-8 code-unit order.
            entries.sort_by(|left, right| left.0.as_bytes().cmp(right.0.as_bytes()));
            for (index, (key, entry)) in entries.iter().enumerate() {
                write_indent(depth + 1, out);
                out.push_str(&serde_json::to_string(key).unwrap_or_default());
                out.push_str(" : ");
                write_value(entry, depth + 1, out);
                if index + 1 != entries.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            write_indent(depth, out);
            out.push('}');
        }
        serde_json::Value::Array(values) => {
            if values.is_empty() {
                out.push_str("[\n\n");
                write_indent(depth, out);
                out.push(']');
                return;
            }
            out.push_str("[\n");
            for (index, entry) in values.iter().enumerate() {
                write_indent(depth + 1, out);
                write_value(entry, depth + 1, out);
                if index + 1 != values.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            write_indent(depth, out);
            out.push(']');
        }
        serde_json::Value::Number(number) => {
            // Swift writes an NSNumber whose integer domain is exact verbatim;
            // routing those through `format_double` would turn 64-bit seeds such
            // as UInt64.max into a rounded Double and break the next decode.
            if number.is_u64() || number.is_i64() {
                out.push_str(&number.to_string());
            } else if let Some(value) = number.as_f64() {
                // Swift's number text: `100` not `100.0`, `1e+20`, `1e-07`, `-0`.
                if let Some(text) = diffuse_kernel::codable::format_double(value) {
                    out.push_str(&text);
                } else {
                    out.push_str(&number.to_string());
                }
            } else {
                out.push_str(&number.to_string());
            }
        }
        other => out.push_str(&serde_json::to_string(other).unwrap_or_default()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;

    fn empty_world() -> RuntimeWorld {
        RuntimeWorld::new(ComponentRegistry::new())
    }

    #[test]
    fn an_empty_scene_writes_the_document_header() {
        let world = empty_world();
        let text = SceneSerializer::serialize(&world).expect("serialize");
        assert_eq!(text, "{\n  \"entities\" : [\n\n  ],\n  \"version\" : 3\n}");
    }

    #[test]
    fn pretty_output_uses_swifts_separator_and_empty_container_layout() {
        // The exact bytes Swift 6.4.1's JSONSerialization(.prettyPrinted, .sortedKeys)
        // produces for an empty array: a blank line between the brackets.
        let world = empty_world();
        let text = SceneSerializer::serialize(&world).expect("serialize");
        assert!(
            text.contains("\"entities\" : ["),
            "wrong key/value separator: {text}"
        );
        assert!(
            text.contains("[\n\n  ]"),
            "empty array must be a blank line: {text}"
        );
        assert!(text.starts_with("{\n"), "must be pretty printed: {text}");
    }

    #[test]
    fn a_round_trip_preserves_the_entity_count_and_order() {
        let mut world = empty_world();
        let first = world.create_entity();
        world.set_component(SceneNameComponent::new("first"), first);
        let second = world.create_entity();
        world.set_component(SceneNameComponent::new("second"), second);

        let text = SceneSerializer::serialize(&world).expect("serialize");
        let mut restored = empty_world();
        let created = SceneSerializer::deserialize(&text, &mut restored).expect("deserialize");

        assert_eq!(created.len(), 2);
        assert_eq!(
            restored
                .component::<SceneNameComponent>(created[0])
                .map(|name| name.value.clone()),
            Some("first".to_string())
        );
        assert_eq!(
            restored
                .component::<SceneNameComponent>(created[1])
                .map(|name| name.value.clone()),
            Some("second".to_string())
        );
    }

    #[test]
    fn a_parent_reference_is_written_as_a_document_index() {
        let mut world = empty_world();
        let parent = world.create_entity();
        let child = world.create_entity();
        world.set_parent(Some(parent), child);

        let text = SceneSerializer::serialize(&world).expect("serialize");
        assert!(
            text.contains("\"parent\" : 0"),
            "parent must be an index: {text}"
        );
    }

    #[test]
    fn an_unsupported_version_is_rejected() {
        let mut world = empty_world();
        let error = SceneSerializer::deserialize("{\"version\":2,\"entities\":[]}", &mut world)
            .expect_err("must reject");
        assert_eq!(error, SceneSerializerError::UnsupportedVersion(2));
    }

    #[test]
    fn a_non_object_entity_list_is_rejected() {
        let mut world = empty_world();
        let error = SceneSerializer::deserialize("{\"version\":3,\"entities\":[1]}", &mut world)
            .expect_err("must reject");
        assert_eq!(error, SceneSerializerError::InvalidFormat);
    }

    #[test]
    fn zero_scale_does_not_produce_nan() {
        use diffuse_math::simd::simd_compat::{Float4, MATRIX_IDENTITY_FLOAT4X4};

        let mut matrix = MATRIX_IDENTITY_FLOAT4X4;
        matrix.set_column(0, Float4::new(0.0, 0.0, 0.0, 0.0));
        let (_, rotation, scale) = decompose_transform(&LocalTransform::new(matrix));
        assert!(scale[0] == 0.0);
        assert!(
            rotation.iter().all(|value| value.is_finite()),
            "zero scale must not produce NaN: {rotation:?}"
        );
    }
}
