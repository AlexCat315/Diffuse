//! Game-save destruction payloads — Swift `GameSaveSupport.swift`.
//!
//! `SceneSerializer` writes three extra component dictionaries into a *game save*
//! document (never into an authored scene or prefab): the per-source runtime
//! state, the live fragment budgets, and the retained-fragment proxies. Load
//! rebuilds `DestructionRuntimeStateResource` from those dictionaries.
//!
//! Byte compatibility (MIGRATION.md §5.4): every document built here is a
//! [`ComponentValue`] object, so the parent serializer's
//! [`super::scene_serializer::to_sorted_pretty`] writes the values with Swift's
//! `JSONSerialization` spelling. Keys are exact and optional snapshots are only
//! emitted when `has_authored_source_snapshot` is set, matching Swift.

use std::collections::{BTreeMap, BTreeSet};

use crate::components::codecs::builtin_component_codecs::BuiltinComponentCodecs;
use crate::components::component_json_helpers::{
    integer, json_to_array, json_to_bool, json_to_dict, json_to_float, json_to_int, number, object,
};
use crate::components::core::value::ComponentValue;
use crate::entity_id::EntityID;
use crate::physics::destruction::{
    DestructibleFragment, DestructibleRetainedFragment, DestructionRuntimeSourceState,
    DestructionRuntimeStateResource,
};
use crate::physics::rigid_body::RigidBody;
use crate::runtime_world::RuntimeWorld;
use crate::serialization::scene_serializer::SceneSerializer;

impl SceneSerializer {
    // MARK: - GameSave destruction state

    /// Swift `serializeDestructionRuntimeSource(_:)`.
    ///
    /// The game-save call site lives in `scene_serializer.rs`; this function is
    /// public in-crate so that path can use it, and the tests below call it
    /// directly in the meantime.
    #[allow(dead_code)]
    pub(crate) fn serialize_destruction_runtime_source(
        source: &DestructionRuntimeSourceState,
    ) -> BTreeMap<String, ComponentValue> {
        let mut encoded = object([
            (
                "hasFractured",
                ComponentValue::Bool(source.has_fractured),
            ),
            (
                "isFullyFractured",
                ComponentValue::Bool(source.is_fully_fractured),
            ),
            (
                "accumulatedDamage",
                number(source.accumulated_damage),
            ),
            (
                "brokenConnectionIDs",
                ComponentValue::Array(
                    source
                        .broken_connection_ids
                        .iter()
                        .map(|fragment_id| integer(i64::from(*fragment_id)))
                        .collect(),
                ),
            ),
            (
                "releasedFragmentIDs",
                ComponentValue::Array(
                    source
                        .released_fragment_ids
                        .iter()
                        .map(|fragment_id| integer(i64::from(*fragment_id)))
                        .collect(),
                ),
            ),
        ]);
        if source.has_authored_source_snapshot {
            let mut snapshot = object([
                (
                    "hasRigidBody",
                    ComponentValue::Bool(source.authored_rigid_body.is_some()),
                ),
                (
                    "hasCollider",
                    ComponentValue::Bool(source.authored_collider.is_some()),
                ),
                (
                    "hasRenderMesh",
                    ComponentValue::Bool(source.authored_render_mesh.is_some()),
                ),
            ]);
            if let Some(rigid_body) = &source.authored_rigid_body {
                snapshot.insert(
                    "rigidbody".to_string(),
                    ComponentValue::Object(BuiltinComponentCodecs::serialize_rigid_body(rigid_body)),
                );
            }
            if let Some(collider) = &source.authored_collider {
                snapshot.insert(
                    "collider".to_string(),
                    ComponentValue::Object(BuiltinComponentCodecs::serialize_collider(collider)),
                );
            }
            if let Some(render_mesh) = &source.authored_render_mesh {
                snapshot.insert(
                    "renderMesh".to_string(),
                    ComponentValue::Object(BuiltinComponentCodecs::serialize_render_mesh(
                        render_mesh,
                    )),
                );
            }
            encoded.insert(
                "authoredSourceSnapshot".to_string(),
                ComponentValue::Object(snapshot),
            );
        }
        encoded
    }

    /// Swift `serializeDestructibleFragment(_:sourceIndex:entity:runtime:)`.
    ///
    /// Remaining budgets are measured against the runtime clock, so a save taken
    /// mid-frame stores how much of each budget is left rather than the original
    /// lifetime.
    #[allow(dead_code)]
    pub(crate) fn serialize_destructible_fragment(
        fragment: &DestructibleFragment,
        source_index: i64,
        entity: EntityID,
        runtime: Option<&DestructionRuntimeStateResource>,
    ) -> BTreeMap<String, ComponentValue> {
        let elapsed_seconds = runtime
            .map(|runtime| runtime.elapsed_seconds)
            .unwrap_or(fragment.spawned_at_seconds);
        let age_seconds = (elapsed_seconds - fragment.spawned_at_seconds).max(0.0);
        let remaining_lifetime = if fragment.maximum_lifetime_seconds > 0.0 {
            (fragment.maximum_lifetime_seconds - age_seconds as f32).max(0.000_001)
        } else {
            0.0
        };

        let mut remaining_sleeping_delay = fragment.sleeping_recycle_delay_seconds;
        let sleeping_since = runtime
            .and_then(|runtime| runtime.sleeping_since_by_fragment.get(&entity))
            .copied();
        if let Some(sleeping_since) = sleeping_since
            && remaining_sleeping_delay > 0.0
        {
            let slept_seconds = (elapsed_seconds - sleeping_since).max(0.0) as f32;
            remaining_sleeping_delay =
                (remaining_sleeping_delay - slept_seconds).max(0.000_001);
        }
        object([
            ("sourceEntity", integer(source_index)),
            (
                "fragmentID",
                integer(i64::from(fragment.fragment_id)),
            ),
            (
                "remainingLifetimeSeconds",
                number(remaining_lifetime),
            ),
            (
                "remainingSleepingRecycleDelaySeconds",
                number(remaining_sleeping_delay),
            ),
            (
                "wasSleeping",
                ComponentValue::Bool(sleeping_since.is_some()),
            ),
        ])
    }

    /// Swift `restoreDestructionRuntimeState(from:entityMap:into:)`.
    ///
    /// Three passes, in document order: source state, live fragments, retained
    /// proxies. The resource is written back only when at least one entity
    /// restored something, so loading an authored document leaves an existing
    /// clock untouched.
    #[allow(dead_code)]
    pub(crate) fn restore_destruction_runtime_state(
        entities: &[serde_json::Value],
        entity_map: &BTreeMap<i64, EntityID>,
        scene: &mut RuntimeWorld,
    ) {
        let mut runtime = scene
            .resource::<DestructionRuntimeStateResource>()
            .unwrap_or_default();
        let mut restored_runtime_state = false;

        for (index, raw) in entities.iter().enumerate() {
            let Some(&entity) = entity_map.get(&(index as i64)) else {
                continue;
            };
            let value = ComponentValue::from_json_value(raw);
            let Some(obj) = json_to_dict(Some(&value)) else {
                continue;
            };
            let Some(components) = json_to_dict(obj.get("components")) else {
                continue;
            };
            let Some(encoded) = json_to_dict(components.get("destructionRuntimeSource")) else {
                continue;
            };

            let mut source = DestructionRuntimeSourceState {
                has_fractured: json_to_bool(encoded.get("hasFractured")).unwrap_or(false),
                is_fully_fractured: json_to_bool(encoded.get("isFullyFractured"))
                    .unwrap_or_else(|| {
                        json_to_bool(encoded.get("hasFractured")).unwrap_or(false)
                    }),
                accumulated_damage: json_to_float(encoded.get("accumulatedDamage")).unwrap_or(0.0),
                broken_connection_ids: fragment_id_set(encoded.get("brokenConnectionIDs")),
                released_fragment_ids: fragment_id_set(encoded.get("releasedFragmentIDs")),
                has_authored_source_snapshot: false,
                authored_rigid_body: None,
                authored_collider: None,
                authored_render_mesh: None,
            };
            if let Some(snapshot) = json_to_dict(encoded.get("authoredSourceSnapshot")) {
                source.has_authored_source_snapshot = true;
                if json_to_bool(snapshot.get("hasRigidBody")) == Some(true)
                    && let Some(rigid_body) = json_to_dict(snapshot.get("rigidbody"))
                {
                    source.authored_rigid_body =
                        Some(BuiltinComponentCodecs::deserialize_rigid_body(rigid_body));
                }
                if json_to_bool(snapshot.get("hasCollider")) == Some(true)
                    && let Some(collider) = json_to_dict(snapshot.get("collider"))
                {
                    source.authored_collider =
                        Some(BuiltinComponentCodecs::deserialize_collider(collider));
                }
                if json_to_bool(snapshot.get("hasRenderMesh")) == Some(true)
                    && let Some(render_mesh) = json_to_dict(snapshot.get("renderMesh"))
                {
                    source.authored_render_mesh =
                        Some(BuiltinComponentCodecs::deserialize_render_mesh(render_mesh));
                }
            }
            runtime.sources.insert(entity, source);
            restored_runtime_state = true;
        }

        for (index, raw) in entities.iter().enumerate() {
            let Some(&entity) = entity_map.get(&(index as i64)) else {
                continue;
            };
            let value = ComponentValue::from_json_value(raw);
            let Some(obj) = json_to_dict(Some(&value)) else {
                continue;
            };
            let Some(components) = json_to_dict(obj.get("components")) else {
                continue;
            };
            let Some(encoded) = json_to_dict(components.get("destructibleFragment")) else {
                continue;
            };
            let Some(source_index) = json_to_int(encoded.get("sourceEntity")) else {
                continue;
            };
            let Some(&source_entity) = entity_map.get(&source_index) else {
                continue;
            };
            let Some(fragment_id_value) = json_to_int(encoded.get("fragmentID")) else {
                continue;
            };
            let Some(fragment_id) = u32::try_from(fragment_id_value).ok() else {
                continue;
            };

            let was_sleeping = json_to_bool(encoded.get("wasSleeping")).unwrap_or(false);
            scene.set_component(
                DestructibleFragment::new(
                    source_entity,
                    fragment_id,
                    runtime.elapsed_seconds,
                    json_to_float(encoded.get("remainingLifetimeSeconds")).unwrap_or(0.0),
                    json_to_float(encoded.get("remainingSleepingRecycleDelaySeconds"))
                        .unwrap_or(0.0),
                ),
                entity,
            );
            if was_sleeping {
                scene.update_component::<RigidBody>(entity, |rigid_body| {
                    rigid_body.is_sleeping = true;
                });
                runtime
                    .sleeping_since_by_fragment
                    .insert(entity, runtime.elapsed_seconds);
            }
            let mut source = runtime
                .sources
                .get(&source_entity)
                .cloned()
                .unwrap_or_default();
            source.has_fractured = true;
            runtime.sources.insert(source_entity, source);
            restored_runtime_state = true;
        }

        for (index, raw) in entities.iter().enumerate() {
            let Some(&entity) = entity_map.get(&(index as i64)) else {
                continue;
            };
            let value = ComponentValue::from_json_value(raw);
            let Some(obj) = json_to_dict(Some(&value)) else {
                continue;
            };
            let Some(components) = json_to_dict(obj.get("components")) else {
                continue;
            };
            let Some(encoded) = json_to_dict(components.get("destructibleRetainedFragment")) else {
                continue;
            };
            let Some(source_index) = json_to_int(encoded.get("sourceEntity")) else {
                continue;
            };
            let Some(&source_entity) = entity_map.get(&source_index) else {
                continue;
            };
            let Some(fragment_id_value) = json_to_int(encoded.get("fragmentID")) else {
                continue;
            };
            let Some(fragment_id) = u32::try_from(fragment_id_value).ok() else {
                continue;
            };
            scene.set_component(
                DestructibleRetainedFragment::new(source_entity, fragment_id),
                entity,
            );
            restored_runtime_state = true;
        }

        if restored_runtime_state {
            scene.set_resource(runtime);
        }
    }
}

/// Swift `Set((jsonToArray(encoded[key]) ?? []).compactMap {
/// jsonToInt($0).flatMap { UInt32(exactly: $0) } })`.
///
/// A `BTreeSet` keeps the `sorted()` order the writer relies on; values outside
/// `UInt32` are dropped exactly like `UInt32(exactly:)`.
fn fragment_id_set(value: Option<&ComponentValue>) -> BTreeSet<u32> {
    json_to_array(value)
        .unwrap_or(&[])
        .iter()
        .filter_map(|value| json_to_int(Some(value)).and_then(|value| u32::try_from(value).ok()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;

    fn empty_world() -> RuntimeWorld {
        RuntimeWorld::new(ComponentRegistry::new())
    }

    #[test]
    fn a_source_document_lists_ids_in_ascending_order() {
        let source = DestructionRuntimeSourceState {
            has_fractured: true,
            is_fully_fractured: false,
            accumulated_damage: 2.5,
            broken_connection_ids: BTreeSet::from([7, 3]),
            released_fragment_ids: BTreeSet::from([9]),
            has_authored_source_snapshot: false,
            authored_rigid_body: None,
            authored_collider: None,
            authored_render_mesh: None,
        };
        let document = SceneSerializer::serialize_destruction_runtime_source(&source);

        let array = json_to_array(document.get("brokenConnectionIDs")).expect("array");
        let ids: Vec<i64> = array
            .iter()
            .filter_map(|value| json_to_int(Some(value)))
            .collect();
        assert_eq!(ids, vec![3, 7]);
        assert_eq!(
            json_to_bool(document.get("hasFractured")),
            Some(true)
        );
        assert!(!document.contains_key("authoredSourceSnapshot"));
    }

    #[test]
    fn a_snapshot_is_only_written_when_the_flag_is_set() {
        let source = DestructionRuntimeSourceState {
            has_authored_source_snapshot: true,
            authored_rigid_body: Some(RigidBody::new(Default::default())),
            ..Default::default()
        };
        let document = SceneSerializer::serialize_destruction_runtime_source(&source);

        let snapshot = json_to_dict(document.get("authoredSourceSnapshot")).expect("snapshot");
        assert_eq!(json_to_bool(snapshot.get("hasRigidBody")), Some(true));
        assert_eq!(json_to_bool(snapshot.get("hasCollider")), Some(false));
        assert!(snapshot.contains_key("rigidbody"));
        assert!(!snapshot.contains_key("collider"));
    }

    #[test]
    fn fragment_budgets_are_relative_to_the_runtime_clock() {
        let fragment = DestructibleFragment::new(EntityID::new(1, 0), 4, 10.0, 30.0, 5.0);
        let document = SceneSerializer::serialize_destructible_fragment(
            &fragment,
            2,
            EntityID::new(1, 0),
            None,
        );
        assert_eq!(
            json_to_int(document.get("sourceEntity")),
            Some(2)
        );
        assert_eq!(json_to_int(document.get("fragmentID")), Some(4));
        assert_eq!(
            json_to_float(document.get("remainingLifetimeSeconds")),
            Some(30.0)
        );
        assert_eq!(
            json_to_float(document.get("remainingSleepingRecycleDelaySeconds")),
            Some(5.0)
        );
        assert_eq!(
            json_to_bool(document.get("wasSleeping")),
            Some(false)
        );

        let mut runtime = DestructionRuntimeStateResource {
            elapsed_seconds: 14.0,
            ..Default::default()
        };
        runtime
            .sleeping_since_by_fragment
            .insert(EntityID::new(1, 0), 12.0);
        let document = SceneSerializer::serialize_destructible_fragment(
            &fragment,
            2,
            EntityID::new(1, 0),
            Some(&runtime),
        );
        assert_eq!(
            json_to_float(document.get("remainingLifetimeSeconds")),
            Some(26.0)
        );
        assert_eq!(
            json_to_float(document.get("remainingSleepingRecycleDelaySeconds")),
            Some(3.0)
        );
        assert_eq!(
            json_to_bool(document.get("wasSleeping")),
            Some(true)
        );
    }

    #[test]
    fn a_zero_lifetime_stays_zero_and_a_sleeping_zero_delay_is_untouched() {
        let fragment = DestructibleFragment::new(EntityID::new(2, 0), 0, 0.0, 0.0, 0.0);
        let mut runtime = DestructionRuntimeStateResource {
            elapsed_seconds: 100.0,
            ..Default::default()
        };
        runtime
            .sleeping_since_by_fragment
            .insert(EntityID::new(2, 0), 10.0);
        let document = SceneSerializer::serialize_destructible_fragment(
            &fragment,
            0,
            EntityID::new(2, 0),
            Some(&runtime),
        );
        assert_eq!(
            json_to_float(document.get("remainingLifetimeSeconds")),
            Some(0.0)
        );
        assert_eq!(
            json_to_float(document.get("remainingSleepingRecycleDelaySeconds")),
            Some(0.0)
        );
    }

    #[test]
    fn restoring_rebuilds_sources_fragments_and_proxies() {
        let mut world = empty_world();
        let source = world.create_entity();
        let fragment = world.create_entity();
        let retained = world.create_entity();
        let entity_map = BTreeMap::from([
            (0, source),
            (1, fragment),
            (2, retained),
        ]);
        let entities = vec![
            serde_json::json!({
                "components": {
                    "destructionRuntimeSource": {
                        "hasFractured": true,
                        "isFullyFractured": false,
                        "accumulatedDamage": 3.0,
                        "brokenConnectionIDs": [1],
                        "releasedFragmentIDs": []
                    }
                }
            }),
            serde_json::json!({
                "components": {
                    "destructibleFragment": {
                        "sourceEntity": 0,
                        "fragmentID": 1,
                        "remainingLifetimeSeconds": 4.0,
                        "remainingSleepingRecycleDelaySeconds": 0.0,
                        "wasSleeping": true
                    }
                }
            }),
            serde_json::json!({
                "components": {
                    "destructibleRetainedFragment": {
                        "sourceEntity": 0,
                        "fragmentID": 2
                    }
                }
            }),
        ];

        SceneSerializer::restore_destruction_runtime_state(&entities, &entity_map, &mut world);

        let stored = world
            .component::<DestructibleFragment>(fragment)
            .expect("fragment");
        assert_eq!(stored.source_entity, source);
        assert_eq!(stored.fragment_id, 1);
        assert_eq!(
            world
                .component::<DestructibleRetainedFragment>(retained)
                .map(|fragment| fragment.fragment_id),
            Some(2)
        );

        let runtime = world
            .resource::<DestructionRuntimeStateResource>()
            .expect("runtime");
        assert!(runtime.sources.get(&source).expect("source").has_fractured);
        assert_eq!(
            runtime.sources.get(&source).expect("source").accumulated_damage,
            3.0
        );
        assert_eq!(
            runtime.sleeping_since_by_fragment.get(&fragment),
            Some(&0.0)
        );
    }

    #[test]
    fn an_incomplete_document_leaves_the_runtime_untouched() {
        let mut world = empty_world();
        let entity = world.create_entity();
        let entity_map = BTreeMap::from([(0, entity)]);
        let entities = vec![serde_json::json!({"components": {}})];

        SceneSerializer::restore_destruction_runtime_state(&entities, &entity_map, &mut world);

        assert!(
            world
                .resource::<DestructionRuntimeStateResource>()
                .is_none()
        );
    }
}
