//! Ported from `Engine/Tests/SceneRuntimeTests/PrefabTests.swift`.
//!
//! Swift's `Prefab.capture(from:root:)` takes a `SceneRuntime`; the Rust port takes
//! the underlying `RuntimeWorld`, so the source scene is handed over by reference.
//! The same applies to `instantiate(into:)`, which takes the target world. Swift's
//! bare `tick()` defaults to `deltaTime: 0`, which is what every call here supplies.

use diffuse_math::simd::simd_compat::Float3;

use crate::components::core::registry::ComponentRegistry;
use crate::entity_id::EntityID;
use crate::physics::collider::{Collider, ColliderShape};
use crate::physics::rigid_body::{RigidBody, RigidBodyMotionType, RigidBodyOptions};
use crate::rendering::render_extraction::RenderMeshComponent;
use crate::runtime_world::LocalTransform;
use crate::scene_bootstrap::{SceneKindComponent, SceneNameComponent};
use crate::scene_graph::prefab::Prefab;
use crate::scene_runtime::SceneRuntime;

/// Builds a small two-node prefab source: a named root with a child, components on both.
fn make_source() -> (SceneRuntime, EntityID) {
    let mut scene = SceneRuntime::new(ComponentRegistry::built_in());
    let root = scene.create_entity();
    scene.set_component(SceneNameComponent::new("Turret"), root);
    scene.set_component(SceneKindComponent::new("Enemy"), root);
    scene.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 1.0, 0.0)),
        root,
    );
    scene.set_component(
        RigidBody::new(RigidBodyOptions {
            motion_type: RigidBodyMotionType::Dynamic,
            mass: 12.0,
            ..RigidBodyOptions::default()
        }),
        root,
    );
    scene.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        root,
    );

    let barrel = scene.create_entity();
    scene.set_component(SceneNameComponent::new("Barrel"), barrel);
    scene.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 0.5, 1.0)),
        barrel,
    );
    scene.set_component(
        RenderMeshComponent::new(3, true, Float3::ONE, None, Vec::new()),
        barrel,
    );
    scene.set_parent(Some(root), barrel);
    (scene, root)
}

/// Capture then instantiate recreates the subtree.
#[test]
fn capture_instantiate_round_trip() {
    let (source, root) = make_source();
    let prefab = Prefab::capture(source.world(), root)
        .expect("capture")
        .expect("prefab");

    let mut target = SceneRuntime::new(ComponentRegistry::built_in());
    let new_root = prefab
        .instantiate(target.world_mut(), None, None)
        .expect("instantiate");
    assert!(new_root.is_some());
    let _ = target.tick(0.0, 0, Vec::new());

    assert_eq!(target.snapshot().entity_count, 2);
    let turret = target.find_entity_named("Turret");
    assert_eq!(turret, new_root);
    let turret = turret.expect("turret");
    assert_eq!(
        target.component::<RigidBody>(turret).map(|body| body.mass),
        Some(12.0)
    );
    assert!(target.component::<Collider>(turret).is_some());

    let barrel = target.find_entity_named("Barrel").expect("barrel");
    assert_eq!(target.parent(barrel), Some(turret));
    assert_eq!(
        target
            .component::<RenderMeshComponent>(barrel)
            .map(|mesh| mesh.mesh_index),
        Some(3)
    );
}

/// Instantiate can be repeated to spawn independent copies.
#[test]
fn instantiate_multiple_times() {
    let (source, root) = make_source();
    let prefab = Prefab::capture(source.world(), root)
        .expect("capture")
        .expect("prefab");

    let mut target = SceneRuntime::new(ComponentRegistry::built_in());
    let a = prefab
        .instantiate(target.world_mut(), None, None)
        .expect("instantiate a");
    let b = prefab
        .instantiate(target.world_mut(), None, None)
        .expect("instantiate b");
    let c = prefab
        .instantiate(target.world_mut(), None, None)
        .expect("instantiate c");

    assert!(a.is_some() && b.is_some() && c.is_some());
    assert!(a != b && b != c && a != c);
    // 2 entities x 3 copies.
    assert_eq!(target.snapshot().entity_count, 6);
    assert_eq!(target.entities_with::<SceneNameComponent>().len(), 6);
}

/// Instantiate applies parent and transform overrides to the root only.
#[test]
fn instantiate_with_overrides() {
    let (source, root) = make_source();
    let prefab = Prefab::capture(source.world(), root)
        .expect("capture")
        .expect("prefab");

    let mut target = SceneRuntime::new(ComponentRegistry::built_in());
    let anchor = target.create_entity();
    target.set_component(SceneNameComponent::new("Anchor"), anchor);

    let placement = LocalTransform::from_translation(Float3::new(10.0, 0.0, -4.0));
    let new_root = prefab
        .instantiate(target.world_mut(), Some(anchor), Some(placement))
        .expect("instantiate");
    assert!(new_root.is_some());
    let _ = target.tick(0.0, 0, Vec::new());

    // Root reparented and repositioned.
    let new_root = new_root.expect("new root");
    assert_eq!(target.parent(new_root), Some(anchor));
    let placement = target.local_transform(new_root).expect("root transform");
    assert!((placement.translation().x - 10.0).abs() < 0.01);
    assert!((placement.translation().z + 4.0).abs() < 0.01);

    // Child keeps its captured local transform (override is root-only).
    let barrel = target.find_entity_named("Barrel").expect("barrel");
    let barrel_transform = target.local_transform(barrel).expect("barrel transform");
    assert!((barrel_transform.translation().z - 1.0).abs() < 0.01);
}

/// Capture returns `None` for an entity outside the scene.
#[test]
fn capture_missing_entity() {
    let empty = SceneRuntime::new(ComponentRegistry::built_in());
    let mut other = SceneRuntime::new(ComponentRegistry::built_in());
    let stray = other.create_entity();
    assert_eq!(
        Prefab::capture(empty.world(), stray).expect("capture"),
        None
    );
}

/// Prefab data survives a raw serialize/load cycle.
#[test]
fn prefab_data_is_relocatable() {
    let (source, root) = make_source();
    let prefab = Prefab::capture(source.world(), root)
        .expect("capture")
        .expect("prefab");

    // Re-wrap the bytes (as if loaded from disk) and instantiate.
    let reloaded = Prefab::new(prefab.data());
    let mut target = SceneRuntime::new(ComponentRegistry::built_in());
    let new_root = reloaded
        .instantiate(target.world_mut(), None, None)
        .expect("instantiate");
    assert!(new_root.is_some());
    assert_eq!(target.snapshot().entity_count, 2);
}
