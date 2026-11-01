//! Ported from `Engine/Tests/SceneRuntimeTests/ComponentRegistryTests.swift`.
//!
//! Swift's `ComponentValue` compares numeric variants semantically
//! (`Int64(exactly:)` / `UInt64(exactly:)`), while the Rust enum derives strict
//! variant equality. [`numeric_equivalent`] reproduces the Swift comparison where
//! a test relies on JSON's single numeric domain.
//!
//! `SceneRuntime` is not `Clone` in Rust (Swift's struct copy cloned the world).
//! `scene_local_registration` therefore builds a fresh runtime over the same
//! registry clone; the behaviour under test — registry ownership across prefab and
//! game-save paths — is unchanged.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use crate::components::core::registry::{
    ComponentCategory, ComponentDecodeContext, ComponentEncodeContext, ComponentRegistry,
    ComponentSchema,
};
use crate::components::core::value::ComponentValue;
use crate::entity_id::{EntityID, RuntimeComponent};
use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::rendering::render_extraction::CameraComponent;
use crate::runtime_world::RuntimeWorld;
use crate::scene_graph::prefab::Prefab;
use crate::scene_runtime::SceneRuntime;
use crate::serialization::game_save::GameSave;
use crate::serialization::scene_serializer::SceneSerializer;

const GOLDEN: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../Engine/Tests/SceneRuntimeTests/Fixtures/component-registry-v3.json"
));

fn object<const N: usize>(entries: [(&str, ComponentValue); N]) -> ComponentValue {
    ComponentValue::Object(
        entries
            .into_iter()
            .map(|(key, value)| (key.to_string(), value))
            .collect::<BTreeMap<_, _>>(),
    )
}

/// Swift's `Int64(exactly:)`.
fn exact_i64(value: f64) -> Option<i64> {
    if value.is_finite()
        && value.fract() == 0.0
        && value >= -9_223_372_036_854_775_808.0
        && value < 9_223_372_036_854_775_808.0
    {
        Some(value as i64)
    } else {
        None
    }
}

/// Swift's `UInt64(exactly:)`.
fn exact_u64(value: f64) -> Option<u64> {
    if value.is_finite() && value.fract() == 0.0 && value >= 0.0
        && value < 18_446_744_073_709_551_616.0
    {
        Some(value as u64)
    } else {
        None
    }
}

/// Swift `ComponentValue.==` for the numeric variants.
fn numeric_equivalent(lhs: &ComponentValue, rhs: &ComponentValue) -> bool {
    use ComponentValue::{Number, SignedInteger, UnsignedInteger};
    match (lhs, rhs) {
        (Number(a), Number(b)) => a == b,
        (SignedInteger(a), SignedInteger(b)) => a == b,
        (UnsignedInteger(a), UnsignedInteger(b)) => a == b,
        (Number(a), SignedInteger(b)) | (SignedInteger(b), Number(a)) => {
            exact_i64(*a) == Some(*b)
        }
        (Number(a), UnsignedInteger(b)) | (UnsignedInteger(b), Number(a)) => {
            exact_u64(*a) == Some(*b)
        }
        (SignedInteger(a), UnsignedInteger(b)) | (UnsignedInteger(b), SignedInteger(a)) => {
            u64::try_from(*a).ok() == Some(*b)
        }
        _ => false,
    }
}

/// Built-in schemas have unique identifiers and omit absent components.
#[test]
fn identifiers_and_absence() {
    let mut world = RuntimeWorld::new(ComponentRegistry::built_in());
    let entity = world.create_entity();
    let schemas = world.component_registry.schemas.clone();
    assert!(!schemas.is_empty());
    let type_ids: BTreeSet<&str> = schemas
        .iter()
        .map(|schema| schema.type_id.as_str())
        .collect();
    assert_eq!(type_ids.len(), schemas.len());

    let mut context = ComponentEncodeContext::new(BTreeMap::from([(entity, 0)]));
    for schema in &schemas {
        assert!(!schema.type_id.is_empty() && !schema.display_name.is_empty());
        assert!(!(schema.has)(&world, entity));
        assert!((schema.encode)(&world, entity, &mut context).is_none());
    }
}

/// Every registered component round-trips canonical JSON and removes through its
/// schema.
#[test]
fn defaults_round_trip() {
    for schema in ComponentRegistry::built_in().schemas {
        let mut world = RuntimeWorld::new(ComponentRegistry::built_in());
        let entity = world.create_entity();
        let endpoint = world.create_entity();
        let mut decode = ComponentDecodeContext::new(BTreeMap::from([(0, entity), (1, endpoint)]));
        if schema.type_id == "constraint" {
            (schema.decode)(
                &object([
                    ("entityA", ComponentValue::Number(0.0)),
                    ("entityB", ComponentValue::Number(1.0)),
                ]),
                entity,
                &mut decode,
                &mut world,
            );
        } else {
            (schema.make_default)(entity, &mut world);
        }
        assert!(
            (schema.has)(&world, entity),
            "missing default for {}",
            schema.type_id
        );

        let mut encode = ComponentEncodeContext::new(BTreeMap::from([(entity, 0), (endpoint, 1)]));
        let value = (schema.encode)(&world, entity, &mut encode)
            .unwrap_or_else(|| panic!("encode returned None for {}", schema.type_id));
        let bytes = value.to_json_value();
        (schema.remove)(entity, &mut world);
        assert!(!(schema.has)(&world, entity));

        let parsed = ComponentValue::from_json_value(&bytes);
        (schema.decode)(&parsed, entity, &mut decode, &mut world);
        let restored = (schema.encode)(&world, entity, &mut encode)
            .unwrap_or_else(|| panic!("re-encode returned None for {}", schema.type_id));
        assert_eq!(
            restored.to_json_value(),
            bytes,
            "round-trip drifted for {}",
            schema.type_id
        );
    }
}

/// Missing component fields rebuild defaults with deterministic particle settings.
#[test]
fn missing_fields() {
    let mut world = RuntimeWorld::new(ComponentRegistry::built_in());
    let entity = world.create_entity();
    let mut context = ComponentDecodeContext::new(BTreeMap::from([(0, entity)]));
    for schema in world.component_registry.schemas.clone() {
        let fields = if schema.type_id == "constraint" {
            object([
                ("entityA", ComponentValue::Number(0.0)),
                ("entityB", ComponentValue::Number(0.0)),
            ])
        } else {
            object([])
        };
        (schema.decode)(&fields, entity, &mut context, &mut world);
        assert!(
            (schema.has)(&world, entity),
            "missing decode defaults for {}",
            schema.type_id
        );
    }
    assert_eq!(
        world.component::<CameraComponent>(entity).map(|camera| camera.is_active),
        Some(false)
    );
    let emitter = world
        .component::<ParticleEmitter>(entity)
        .expect("particle emitter default");
    assert_eq!(emitter.settings, ParticleEmitter::default().settings);
    assert_eq!(emitter.particles().len(), 0);
}

/// Scene JSON preserves all component values and references.
#[test]
fn legacy_golden() {
    let mut restored = SceneRuntime::new(ComponentRegistry::built_in());
    let created = SceneSerializer::deserialize(GOLDEN, restored.world_mut()).expect("deserialize");
    assert_eq!(created.len(), 2);

    let expected = ComponentValue::from_json_value(
        &serde_json::from_str::<Value>(GOLDEN).expect("golden JSON"),
    );
    let actual = ComponentValue::from_json_value(
        &serde_json::from_str::<Value>(
            &SceneSerializer::serialize(restored.world()).expect("serialize"),
        )
        .expect("serialized JSON"),
    );
    assert_eq!(actual, expected);

    let document: Value = serde_json::from_str(GOLDEN).expect("golden JSON");
    let entities = document["entities"]
        .as_array()
        .expect("entities array");
    let components = entities[0]["components"]
        .as_object()
        .expect("components object");
    let keys: BTreeSet<String> = components.keys().cloned().collect();
    let schema_ids: BTreeSet<String> = restored
        .component_registry()
        .component_schemas()
        .into_iter()
        .map(|schema| schema.type_id)
        .collect();
    assert_eq!(keys, schema_ids);
}

/// Registrations belong to a scene and survive copying, prefab and game-save
/// paths.
#[test]
fn scene_local_registration() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let root = scene.create_entity();
    scene
        .world_mut()
        .component_registry
        .register(counter_schema());
    scene.set_component(RegistryCounter { value: 42 }, root);
    assert!(
        SceneRuntime::new(ComponentRegistry::built_in())
            .component_registry()
            .get("test.counter")
            .is_none()
    );

    // Swift's `var copied = scene` cloned the world; Rust rebuilds it over the same
    // registry because `SceneRuntime` has no `Clone`.
    let mut copied = SceneRuntime::new(scene.component_registry().clone());
    assert!(copied.component_registry().get("test.counter").is_some());
    let prefab = Prefab::capture(scene.world(), root)
        .expect("capture prefab")
        .expect("prefab");
    let spawned = prefab
        .instantiate(copied.world_mut(), None, None)
        .expect("instantiate prefab")
        .expect("spawned root");
    assert_eq!(
        copied
            .component::<RegistryCounter>(spawned)
            .map(|counter| counter.value),
        Some(42)
    );

    let save = GameSave::capture(&scene, BTreeMap::new()).expect("capture save");
    let mut restored = SceneRuntime::new(scene.component_registry().clone());
    save.restore_scene(&mut restored).expect("restore save");
    let first = restored.entities().first().copied().expect("restored entity");
    assert_eq!(
        restored
            .component::<RegistryCounter>(first)
            .map(|counter| counter.value),
        Some(42)
    );
}

/// Typed integer component values compare equally after JSON normalization.
#[test]
fn numeric_representations() {
    for value in [
        ComponentValue::SignedInteger(42),
        ComponentValue::UnsignedInteger(42),
        ComponentValue::SignedInteger(-42),
        ComponentValue::SignedInteger(i64::MAX),
        ComponentValue::UnsignedInteger(u64::MAX),
        ComponentValue::Number(18_014_398_509_481_984.0),
    ] {
        let encoded = serde_json::to_string(&value).expect("encode value");
        let decoded: ComponentValue = serde_json::from_str(&encoded).expect("decode value");
        assert!(
            numeric_equivalent(&decoded, &value),
            "{value:?} drifted to {decoded:?}"
        );
    }
    assert!(!numeric_equivalent(
        &ComponentValue::UnsignedInteger(u64::MAX),
        &ComponentValue::Number(u64::MAX as f64)
    ));
}

/// Component JSON preserves large integer seeds and booleans through JSON.
#[test]
fn lossless_component_value() {
    for boolean in [true, false] {
        assert_eq!(
            ComponentValue::from_json_value(&Value::Bool(boolean)),
            ComponentValue::Bool(boolean)
        );
    }
    for number in [0i8, 1, -1] {
        assert_eq!(
            ComponentValue::from_json_value(&Value::from(number)),
            ComponentValue::Number(number as f64)
        );
    }

    let value = ComponentValue::from_json_value(&serde_json::json!({
        "seed": u64::MAX,
        "negative": i64::MIN,
        "enabled": true,
        "list": [1.25, 2.5]
    }));
    let data = serde_json::to_string(&value).expect("encode value");
    let decoded: ComponentValue = serde_json::from_str(&data).expect("decode value");
    assert_eq!(decoded, value);

    let object = value.object_value().expect("object value");
    assert_eq!(
        object.get("seed"),
        Some(&ComponentValue::UnsignedInteger(u64::MAX))
    );
    assert_eq!(
        object.get("enabled").and_then(ComponentValue::as_bool),
        Some(true)
    );
}

#[derive(Clone, Debug, PartialEq)]
struct RegistryCounter {
    value: i64,
}

impl RuntimeComponent for RegistryCounter {}

fn encode_counter(
    world: &RuntimeWorld,
    entity: EntityID,
    _context: &mut ComponentEncodeContext,
) -> Option<ComponentValue> {
    world.component::<RegistryCounter>(entity).map(|counter| {
        ComponentValue::Object(BTreeMap::from([(
            "value".to_string(),
            ComponentValue::Number(counter.value as f64),
        )]))
    })
}

fn decode_counter(
    value: &ComponentValue,
    entity: EntityID,
    _context: &mut ComponentDecodeContext,
    world: &mut RuntimeWorld,
) {
    let value = value
        .object_value()
        .and_then(|object| object.get("value"))
        .and_then(ComponentValue::numeric_value)
        .unwrap_or(0.0) as i64;
    let _ = world.set_component(RegistryCounter { value }, entity);
}

fn default_counter(entity: EntityID, world: &mut RuntimeWorld) {
    let _ = world.set_component(RegistryCounter { value: 0 }, entity);
}

fn counter_schema() -> ComponentSchema {
    ComponentSchema::for_component::<RegistryCounter>(
        "test.counter",
        "Counter",
        ComponentCategory::Gameplay,
        encode_counter,
        decode_counter,
        default_counter,
    )
}
