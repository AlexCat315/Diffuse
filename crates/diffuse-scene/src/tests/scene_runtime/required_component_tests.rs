//! Ported from `Engine/Tests/SceneRuntimeTests/RequiredComponentTests.swift`.
//!
//! The Swift schemas captured `id`/`value`/`unavailable`/`incompatibleWith` in
//! their closures; Rust's `EncodeFn`/`DecodeFn` are plain function pointers, so
//! the per-schema values live in the capture-allowed `make_default` closure and
//! in each component's `DEFAULT_VALUE`. Swift's `let copy = scene` value copy is
//! `scene.clone()` (`SceneRuntime` derives `Clone`).

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::Float3;
use serde_json::Value;

use crate::components::core::registry::{
    ComponentCategory, ComponentDecodeContext, ComponentDependencyError, ComponentEncodeContext,
    ComponentRegistry, ComponentSchema,
};
use crate::components::core::value::{ComponentValue, ManifestComponent};
use crate::components::editing::ComponentWriteMode;
use crate::entity_id::EntityID;
use crate::entity_id::RuntimeComponent;
use crate::rendering::render_extraction::{CameraComponent, LightComponent};
use crate::runtime_world::{LocalTransform, RuntimeWorld};
use crate::scene_graph::prefab::Prefab;
use crate::scene_runtime::SceneRuntime;
use crate::serialization::game_save::GameSave;
use crate::serialization::scene_serializer::SceneSerializer;

trait RequiredTestValue: RuntimeComponent {
    const DEFAULT_VALUE: i64;
    fn value(&self) -> i64;
    fn with_value(value: i64) -> Self;
}

#[derive(Clone, Debug, PartialEq)]
struct RequiredRoot {
    value: i64,
}
#[derive(Clone, Debug, PartialEq)]
struct RequiredLeft {
    value: i64,
}
#[derive(Clone, Debug, PartialEq)]
struct RequiredRight {
    value: i64,
}
#[derive(Clone, Debug, PartialEq)]
struct RequiredLeaf {
    value: i64,
}

macro_rules! required_test_value {
    ($type:ty, $default:expr) => {
        impl RequiredTestValue for $type {
            const DEFAULT_VALUE: i64 = $default;
            fn value(&self) -> i64 {
                self.value
            }
            fn with_value(value: i64) -> Self {
                Self { value }
            }
        }
        impl RuntimeComponent for $type {}
    };
}

required_test_value!(RequiredRoot, 0);
required_test_value!(RequiredLeft, 0);
required_test_value!(RequiredRight, 0);
required_test_value!(RequiredLeaf, 7);

#[derive(Clone, Debug, Default, PartialEq)]
struct RequiredCreationLog {
    ids: Vec<String>,
}

fn encode_impl<C: RequiredTestValue>(
    world: &RuntimeWorld,
    entity: EntityID,
    _context: &mut ComponentEncodeContext,
) -> Option<ComponentValue> {
    world.component::<C>(entity).map(|component| {
        ComponentValue::Object(BTreeMap::from([(
            "value".to_string(),
            ComponentValue::SignedInteger(component.value()),
        )]))
    })
}

fn decode_impl<C: RequiredTestValue>(
    data: &ComponentValue,
    entity: EntityID,
    _context: &mut ComponentDecodeContext,
    world: &mut RuntimeWorld,
) {
    let value = data
        .object_value()
        .and_then(|object| object.get("value"))
        .and_then(|value| match value {
            ComponentValue::SignedInteger(value) => Some(*value),
            ComponentValue::Number(value) => Some(*value as i64),
            _ => None,
        })
        .unwrap_or(C::DEFAULT_VALUE);
    let _ = world.set_component(C::with_value(value), entity);
}

fn test_schema<C: RequiredTestValue>(
    id: &str,
    requires: &[&str],
    value: i64,
    unavailable: bool,
    incompatible_with: &[&str],
) -> ComponentSchema {
    let id_owned = id.to_string();
    let mut schema = ComponentSchema::for_component::<C>(
        id,
        id,
        ComponentCategory::Gameplay,
        encode_impl::<C>,
        decode_impl::<C>,
        move |entity, world| {
            let mut log = world.resource::<RequiredCreationLog>().unwrap_or_default();
            log.ids.push(id_owned.clone());
            world.set_resource(log);
            if !unavailable {
                let _ = world.set_component(C::with_value(value), entity);
            }
        },
    );
    schema.requires = requires.iter().map(|value| value.to_string()).collect();
    schema.incompatible_with = incompatible_with
        .iter()
        .map(|value| value.to_string())
        .collect();
    schema
}

fn dependency_registry() -> ComponentRegistry {
    let mut registry = ComponentRegistry::new();
    registry.register(test_schema::<RequiredRoot>(
        "test.root",
        &["test.left", "test.right"],
        0,
        false,
        &[],
    ));
    registry.register(test_schema::<RequiredLeft>(
        "test.left",
        &["test.leaf"],
        0,
        false,
        &[],
    ));
    registry.register(test_schema::<RequiredRight>(
        "test.right",
        &["test.leaf"],
        0,
        false,
        &[],
    ));
    registry
}

#[test]
fn spatial_component_writes_insert_transforms_and_preserve_authored_transforms() {
    let mut world = RuntimeWorld::default();
    world.component_registry.validate_requirements().unwrap();
    let camera = world.create_entity();
    assert!(world.set_component(CameraComponent::default(), camera));
    assert_eq!(
        world.component::<LocalTransform>(camera),
        Some(LocalTransform::IDENTITY)
    );
    let authored = LocalTransform::from_translation_rotation_scale(
        Float3::new(2.0, 3.0, 4.0),
        Default::default(),
        Float3::new(1.0, 1.0, 1.0),
    );
    let transform_updated = world.set_local_transform(authored, camera);
    let updated_camera = CameraComponent {
        near: 0.5,
        ..CameraComponent::default()
    };
    let camera_updated = world.set_component(updated_camera, camera);
    assert!(transform_updated && camera_updated);
    assert_eq!(world.component::<LocalTransform>(camera), Some(authored));
    let _ = world.remove_component::<CameraComponent>(camera);
    assert_eq!(world.component::<LocalTransform>(camera), Some(authored));

    let light = world.create_entity();
    assert!(world.set_component(LightComponent::default(), light));
    assert_eq!(
        world.component::<LocalTransform>(light),
        Some(LocalTransform::IDENTITY)
    );
    world.propagate_transforms_default();
    assert_eq!(
        world.world_transform(camera).map(|t| t.translation()),
        Some(authored.translation())
    );
    assert_eq!(
        world.world_transform(light).map(|t| t.translation()),
        Some(Float3::ZERO)
    );
}

#[test]
fn forward_declarations_and_diamond_dependencies_have_deterministic_insertion_order() {
    let mut registry = dependency_registry();
    assert_eq!(
        registry.validate_requirements(),
        Err(ComponentDependencyError::MissingRequirement {
            component: "test.left".to_string(),
            required: "test.leaf".to_string(),
        })
    );
    registry.register(test_schema::<RequiredLeaf>("test.leaf", &[], 7, false, &[]));
    registry.validate_requirements().unwrap();
    let mut scene = SceneRuntime::new(registry);
    let entity = scene.create_entity();
    scene.add_component("test.root", entity).unwrap();
    assert_eq!(
        scene.resource::<RequiredCreationLog>().unwrap().ids,
        vec!["test.leaf", "test.left", "test.right", "test.root"]
    );
    assert_eq!(scene.component::<RequiredLeaf>(entity).unwrap().value, 7);
    let copy = scene.clone();
    let _ = scene.set_component(RequiredLeaf { value: 99 }, entity);
    let _ = scene.remove_component::<RequiredRoot>(entity);
    scene.add_component("test.root", entity).unwrap();
    assert_eq!(scene.component::<RequiredLeaf>(entity).unwrap().value, 99);
    assert_eq!(
        scene.resource::<RequiredCreationLog>().unwrap().ids,
        vec![
            "test.leaf",
            "test.left",
            "test.right",
            "test.root",
            "test.root"
        ]
    );
    assert_eq!(copy.component::<RequiredLeaf>(entity).unwrap().value, 7);
}

#[test]
fn missing_requirements_cycles_and_unavailable_defaults_reject_atomically() {
    let mut missing = dependency_registry();
    let mut cyclic = ComponentRegistry::new();
    cyclic.register(test_schema::<RequiredRoot>(
        "test.root",
        &["test.left"],
        0,
        false,
        &[],
    ));
    cyclic.register(test_schema::<RequiredLeft>(
        "test.left",
        &["test.root"],
        0,
        false,
        &[],
    ));
    assert_eq!(
        cyclic.validate_requirements(),
        Err(ComponentDependencyError::Cycle(vec![
            "test.root".to_string(),
            "test.left".to_string(),
            "test.root".to_string()
        ]))
    );
    missing.register(test_schema::<RequiredLeaf>("test.leaf", &[], 0, true, &[]));
    for registry in [dependency_registry(), cyclic, missing] {
        let mut scene = SceneRuntime::new(registry);
        let entity = scene.create_entity();
        let revision = scene.snapshot().revision;
        assert!(!scene.set_component(RequiredRoot { value: 2 }, entity));
        assert!(scene.add_component("test.root", entity).is_err());
        assert!(!scene.has_component::<RequiredRoot>(entity));
        assert!(!scene.has_component::<RequiredLeaf>(entity));
        assert!(scene.resource::<RequiredCreationLog>().is_none());
        assert_eq!(scene.snapshot().revision, revision);
    }
}

#[test]
fn failed_dependency_defaults_roll_back_earlier_dependencies_and_conflicts() {
    let mut registry = ComponentRegistry::new();
    registry.register(test_schema::<RequiredRoot>(
        "test.root",
        &["test.left", "test.right"],
        0,
        false,
        &[],
    ));
    registry.register(test_schema::<RequiredLeft>("test.left", &[], 0, false, &[]));
    registry.register(test_schema::<RequiredRight>(
        "test.right",
        &[],
        0,
        true,
        &[],
    ));
    let mut scene = SceneRuntime::new(registry);
    let entity = scene.create_entity();
    let revision = scene.snapshot().revision;
    assert_eq!(
        scene
            .add_component("test.root", entity)
            .unwrap_err()
            .dependency_error(),
        Some(&ComponentDependencyError::DefaultUnavailable(
            "test.right".to_string()
        ))
    );
    assert!(!scene.has_component::<RequiredLeft>(entity));
    assert!(scene.resource::<RequiredCreationLog>().is_none());
    assert_eq!(scene.snapshot().revision, revision);
    assert!(!scene.set_component(RequiredRoot { value: 2 }, entity));
    assert_eq!(scene.snapshot().revision, revision);

    for left_declares_conflict in [true, false] {
        let mut conflicting = ComponentRegistry::new();
        conflicting.register(test_schema::<RequiredRoot>(
            "test.root",
            &["test.left", "test.right"],
            0,
            false,
            &[],
        ));
        conflicting.register(test_schema::<RequiredLeft>(
            "test.left",
            &[],
            0,
            false,
            if left_declares_conflict {
                &["test.right"]
            } else {
                &[]
            },
        ));
        conflicting.register(test_schema::<RequiredRight>(
            "test.right",
            &[],
            0,
            false,
            if left_declares_conflict {
                &[]
            } else {
                &["test.left"]
            },
        ));
        let mut rejected = SceneRuntime::new(conflicting);
        let rejected_entity = rejected.create_entity();
        assert!(!rejected.set_component(RequiredRoot { value: 2 }, rejected_entity));
        assert!(!rejected.has_component::<RequiredLeft>(rejected_entity));
    }
}

#[test]
fn decode_prefab_and_save_flows_supply_dependencies_without_persisting_a_second_transform() {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = scene.create_entity();
    let mut context = ComponentDecodeContext::new(BTreeMap::from([(0_i64, entity)]));
    SceneSerializer::apply_component_document(
        scene.world_mut(),
        entity,
        &[ManifestComponent::new(
            "camera",
            ComponentValue::Object(BTreeMap::new()),
        )],
        &mut context,
    );
    assert_eq!(
        scene.component::<LocalTransform>(entity),
        Some(LocalTransform::IDENTITY)
    );
    let document = SceneSerializer::serialize(scene.world()).unwrap();
    let document: Value = serde_json::from_str(&document).unwrap();
    let records = document["entities"].as_array().unwrap();
    assert!(
        records[0]["components"]
            .get("localTransform")
            .is_none_or(Value::is_null)
    );
    assert!(!records[0]["translation"].is_null());

    let mut registry = dependency_registry();
    registry.register(test_schema::<RequiredLeaf>("test.leaf", &[], 7, false, &[]));
    let mut custom = SceneRuntime::new(registry);
    let root = custom.create_entity();
    custom
        .set_component_data(
            &ComponentValue::Object(BTreeMap::from([(
                "value".to_string(),
                ComponentValue::Number(31.0),
            )])),
            "test.root",
            root,
            ComponentWriteMode::Replace,
        )
        .unwrap();
    let _ = custom.set_component(RequiredLeaf { value: 99 }, root);
    let prefab = Prefab::capture(custom.world(), root).unwrap().unwrap();
    let copy = prefab
        .instantiate(custom.world_mut(), None, None)
        .unwrap()
        .unwrap();
    assert_eq!(custom.component::<RequiredLeaf>(copy).unwrap().value, 99);
    assert_eq!(custom.component::<RequiredRoot>(copy).unwrap().value, 31);
    let save = GameSave::capture(&custom, BTreeMap::new()).unwrap();
    let mut restored = SceneRuntime::new({
        let mut registry = dependency_registry();
        registry.register(test_schema::<RequiredLeaf>("test.leaf", &[], 7, false, &[]));
        registry
    });
    save.restore_scene(&mut restored).unwrap();
    assert!(restored.entities().into_iter().all(|entity| {
        restored
            .component::<RequiredLeaf>(entity)
            .is_some_and(|leaf| leaf.value == 99)
    }));
}

#[test]
fn document_provided_dependencies_are_available_when_constructing_missing_transitive_defaults() {
    let mut registry = ComponentRegistry::new();
    registry.register(test_schema::<RequiredRoot>(
        "test.root",
        &["test.left"],
        0,
        false,
        &[],
    ));
    // The left component's default reads the leaf already present on the entity.
    let mut left = ComponentSchema::for_component::<RequiredLeft>(
        "test.left",
        "test.left",
        ComponentCategory::Gameplay,
        encode_impl::<RequiredLeft>,
        decode_impl::<RequiredLeft>,
        move |entity, world| {
            let value = world
                .component::<RequiredLeaf>(entity)
                .map(|leaf| leaf.value)
                .unwrap_or(-1);
            let _ = world.set_component(RequiredLeft { value }, entity);
        },
    );
    left.requires = vec!["test.leaf".to_string()];
    registry.register(left);
    registry.register(test_schema::<RequiredLeaf>("test.leaf", &[], 7, false, &[]));
    let mut scene = SceneRuntime::new(registry);
    let entity = scene.create_entity();
    let mut context = ComponentDecodeContext::new(BTreeMap::from([(0_i64, entity)]));
    SceneSerializer::apply_component_document(
        scene.world_mut(),
        entity,
        &[
            ManifestComponent::new("test.root", ComponentValue::Object(BTreeMap::new())),
            ManifestComponent::new(
                "test.leaf",
                ComponentValue::Object(BTreeMap::from([(
                    "value".to_string(),
                    ComponentValue::Number(99.0),
                )])),
            ),
        ],
        &mut context,
    );
    assert_eq!(scene.component::<RequiredLeaf>(entity).unwrap().value, 99);
    assert_eq!(scene.component::<RequiredLeft>(entity).unwrap().value, 99);
}
