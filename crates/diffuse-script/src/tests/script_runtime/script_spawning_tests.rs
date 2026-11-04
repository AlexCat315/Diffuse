//! Ported from `Engine/Tests/ScriptRuntimeTests/ScriptSpawningTests.swift`.
//!
//! Swift's `Prefab.captureFull(from:root:)` and `prefab.instantiateFull(into:)`
//! are Rust's `Prefab::capture(world, root)` and
//! `Prefab::instantiate(world, parent, transform)`, both returning
//! `Result<Option<_>>` — the `try #require` pairs become `.expect().expect()`.
//!
//! `SceneRuntime.setParent(root, for: child)` is `set_parent(Some(root), child)`,
//! and `scene.spatialIndex.entries` is `scene.spatial_index().entries`.
//!
//! `ScriptContext` spells its entity-scoped helpers explicitly:
//! `createEntity()` → `create_entity(None, LocalTransform::default())`,
//! `context.entity(named:)` → `entity_named`, `setLocalTransform(_:for:)` →
//! `set_local_transform_for`, `translate(_:for:)` → `translate_for`.
//! `physicsRaycast(query)` needs the filter Swift defaults, so
//! `PhysicsQueryFilter::default()` is passed explicitly.

use std::sync::Arc;

use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::physics::collider::{Collider, ColliderShape};
use diffuse_scene::physics::queries::physics_query_types::{
    PhysicsQueryFilter, PhysicsRaycastQuery,
};
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_graph::prefab::Prefab;
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::core::script_component::{ScriptBinding, ScriptComponent};
use crate::core::script_context::ScriptContext;
use crate::core::script_lifecycle::Script;
use crate::core::script_runtime::ScriptRuntime;
use crate::interop::scene_serializer_script_support::PrefabScriptSupport;
use crate::presets::script_presets::ScriptVar;

/// Swift's `SceneRuntime()`; the Rust runtime takes its component registry.
fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

/// Swift's `SpawnedEntities` hand-off out of a callback.
#[derive(Clone, Debug, PartialEq)]
struct SpawnedEntities {
    entities: Vec<diffuse_scene::entity_id::EntityID>,
}

fn sphere_collider(radius: f32) -> Collider {
    Collider::with_shape(ColliderShape::Sphere {
        radius,
        center: Float3::ZERO,
    })
}

/// `native prefab loading restores scripts onto remapped child entities`
#[test]
fn native_prefab_scripts() {
    let mut template = scene();
    let root = template.create_entity();
    let child = template.create_entity();
    template.set_parent(Some(root), child);
    template.set_component(
        ScriptComponent::new(vec![ScriptBinding::with_identifier("game.child")]),
        child,
    );
    let prefab = Prefab::capture_full(&template, root)
        .expect("the subtree captures")
        .expect("the root is authored");

    let mut destination = scene();
    destination.create_entity();
    let removed = destination.create_entity();
    destination.create_entity();
    destination.destroy_entity(removed);
    let new_root = prefab
        .instantiate_full(&mut destination, None, None)
        .expect("the prefab instantiates")
        .expect("the prefab has a root");
    let new_child = destination
        .children(new_root)
        .first()
        .copied()
        .expect("the root keeps its child");
    assert!(destination.component::<ScriptComponent>(new_root).is_none());
    assert_eq!(
        destination
            .component::<ScriptComponent>(new_child)
            .and_then(|component| component.bindings.first().map(|b| b.identifier.clone())),
        Some(Some("game.child".to_string()))
    );
    assert_eq!(destination.snapshot().entity_count, 4);
}

/// `Batched script transforms reach descendants at the phase boundary`
#[test]
fn flushes_transform_batch() {
    let scripts = ScriptRuntime::new();
    let handle = scripts.register(
        Script::default().on_update(Arc::new(|context: &mut ScriptContext<'_, '_>| {
            // Swift's `for x in 1...32`: the last write wins.
            for x in 1..=32 {
                context.set_local_transform(LocalTransform::from_translation(Float3::new(
                    x as f32, 0.0, 0.0,
                )));
            }
        })),
        None,
    );
    let mut scene = scene();
    scene.set_script_driver(Box::new(scripts));
    let parent = scene.create_entity();
    let child = scene.create_entity();
    scene.set_parent(Some(parent), child);
    scene.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 2.0, 0.0)),
        child,
    );
    scene.set_component(sphere_collider(0.25), child);
    scene.set_component(ScriptComponent::from_scripts([handle]), parent);
    scene.tick(0.0, 0, Vec::new());
    assert_eq!(
        scene.world_transform(child).map(|t| t.translation()),
        Some(Float3::new(32.0, 2.0, 0.0))
    );
    assert!(
        scene
            .spatial_index()
            .entries
            .iter()
            .any(|entry| entry.entity == child)
    );
}

/// `Physics queries see pending local transform writes inside a callback`
#[test]
fn queries_pending_transforms() {
    let scripts = ScriptRuntime::new();
    let handle = scripts.register(
        Script::default().on_start(Arc::new(|context: &mut ScriptContext<'_, '_>| {
            let target = context.create_entity(None, LocalTransform::default());
            context.set_component_for(sphere_collider(0.5), target);
            context.set_local_transform_for(
                LocalTransform::from_translation(Float3::new(5.0, 0.0, 0.0)),
                target,
            );
            let query = PhysicsRaycastQuery::with_distance(
                Float3::new(3.0, 0.0, 0.0),
                Float3::new(1.0, 0.0, 0.0),
                4.0,
            );
            assert_eq!(
                context
                    .physics_raycast(query, PhysicsQueryFilter::default())
                    .map(|hit| hit.entity),
                Some(target)
            );
            context.translate_for(Float3::new(10.0, 0.0, 0.0), target);
            assert!(
                context
                    .physics_raycast(query, PhysicsQueryFilter::default())
                    .is_none()
            );
        })),
        None,
    );
    let mut scene = scene();
    scene.set_script_driver(Box::new(scripts));
    let owner = scene.create_entity();
    scene.set_component(ScriptComponent::from_scripts([handle]), owner);
    scene.tick(0.0, 0, Vec::new());
}

/// `a script creates and configures an entity visible to the same frame`
#[test]
fn creates_entity() {
    let scripts = ScriptRuntime::new();
    let handle = scripts.register(
        Script::default().on_start(Arc::new(|context: &mut ScriptContext<'_, '_>| {
            let entity = context.create_entity(
                Some("Bullet"),
                LocalTransform::from_translation(Float3::new(1.0, 2.0, 3.0)),
            );
            context.set_component_for(sphere_collider(0.25), entity);
            context.set_resource(SpawnedEntities {
                entities: vec![entity],
            });
            assert_eq!(context.entity_named("Bullet"), Some(entity));
            assert_eq!(
                context.world_transform_of(entity).map(|t| t.translation()),
                Some(Float3::new(1.0, 2.0, 3.0))
            );
        })),
        None,
    );
    let mut scene = scene();
    scene.set_script_driver(Box::new(scripts));
    let owner = scene.create_entity();
    scene.set_component(ScriptComponent::from_scripts([handle]), owner);
    scene.tick(0.0, 0, Vec::new());

    let created = scene
        .resource::<SpawnedEntities>()
        .and_then(|spawned| spawned.entities.first().copied())
        .expect("the callback published its entity");
    assert_eq!(scene.snapshot().entity_count, 2);
    assert!(
        scene
            .spatial_index()
            .entries
            .iter()
            .any(|entry| entry.entity == created)
    );
}

/// `prefab instances preserve hierarchy and get independent script state`
#[test]
fn instantiates_gameplay_prefab() {
    let mut template = scene();
    let root = template.create_entity();
    let child = template.create_entity();
    template.set_local_transform(LocalTransform::IDENTITY, root);
    template.set_local_transform(LocalTransform::IDENTITY, child);
    template.set_parent(Some(root), child);
    template.set_component(
        ScriptComponent::new(vec![ScriptBinding::with_identifier("game.counter")]),
        child,
    );
    let prefab = Prefab::capture_full(&template, root)
        .expect("the subtree captures")
        .expect("the root is authored");

    let scripts = ScriptRuntime::new();
    // Each instance owns its own counter, as the captured `ScriptVar` does.
    scripts.register_factory(
        Some("game.counter"),
        "{}",
        crate::core::script_definition::ScriptDefinition::default(),
        || {
            let count = ScriptVar::new(0.0_f32);
            Script::default().on_update(Arc::new(move |context: &mut ScriptContext<'_, '_>| {
                let value = count.with_value(|value| {
                    *value += 1.0;
                    *value
                });
                context.set_local_transform(LocalTransform::from_translation(Float3::new(
                    value, 0.0, 0.0,
                )));
            }))
        },
    );
    let spawner = scripts.register(
        Script::default().on_start(Arc::new({
            let prefab = prefab.clone();
            move |context: &mut ScriptContext<'_, '_>| {
                let owner = context.entity;
                let first = context
                    .instantiate(&prefab, Some(owner), None)
                    .expect("the first instance instantiates")
                    .expect("the prefab has a root");
                let second = context
                    .instantiate(&prefab, Some(owner), None)
                    .expect("the second instance instantiates")
                    .expect("the prefab has a root");
                context.set_resource(SpawnedEntities {
                    entities: vec![first, second],
                });
            }
        })),
        None,
    );

    let mut scene = scene();
    scene.set_script_driver(Box::new(scripts));
    let owner = scene.create_entity();
    scene.set_local_transform(LocalTransform::IDENTITY, owner);
    scene.set_component(ScriptComponent::from_scripts([spawner]), owner);
    scene.tick(0.0, 0, Vec::new());
    scene.tick(0.0, 0, Vec::new());

    let roots = scene
        .resource::<SpawnedEntities>()
        .expect("the spawner published its roots")
        .entities;
    assert_eq!(roots.len(), 2);
    for root in roots {
        assert_eq!(scene.parent(root), Some(owner));
        let child = scene
            .children(root)
            .first()
            .copied()
            .expect("the instance keeps its child");
        assert_eq!(
            scene.local_transform(child).map(|t| t.translation()),
            Some(Float3::new(2.0, 0.0, 0.0))
        );
    }
    assert_eq!(template.snapshot().entity_count, 2);
}

/// `invalid prefab documents fail before creating any entities`
#[test]
fn rejects_malformed_prefab() {
    let malformed = Prefab::new(r#"{"version":1,"entities":[{},42]}"#);
    let scripts = ScriptRuntime::new();
    let handle = scripts.register(
        Script::default().on_start(Arc::new(move |context: &mut ScriptContext<'_, '_>| {
            assert!(context.instantiate(&malformed, None, None).is_err());
            assert_eq!(context.entities().len(), 1);
        })),
        None,
    );
    let mut scene = scene();
    scene.set_script_driver(Box::new(scripts));
    let owner = scene.create_entity();
    scene.set_component(ScriptComponent::from_scripts([handle]), owner);
    scene.tick(0.0, 0, Vec::new());
    assert_eq!(scene.snapshot().entity_count, 1);
}
