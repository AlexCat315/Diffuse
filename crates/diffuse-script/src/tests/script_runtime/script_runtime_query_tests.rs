//! Ported from `Engine/Tests/ScriptRuntimeTests/ScriptRuntimeQueryTests.swift`.
//!
//! Swift's `Collider(shape:layerID:layerMask:)` and
//! `Collider(shape:isTrigger:layerID:layerMask:)` are memberwise initializers;
//! Rust builds the first shape with `Collider::with_shape` and assigns the
//! remaining public fields.
//!
//! `SpatialAABB(center:halfExtents:)` is
//! `SpatialAABB::from_center_half_extents(center, half_extents)` since the Rust
//! struct stores `min`/`max`. `PhysicsRaycastQuery(origin:direction:maxDistance:)`
//! is `PhysicsRaycastQuery::with_distance(origin, direction, max_distance)`.
//!
//! Swift's `runtime.tick()` takes no arguments; the Rust tick always takes
//! `(delta_time, frame_index, input_events)`.

use std::collections::BTreeSet;

use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::physics::collider::{Collider, ColliderShape, SpatialAABB};
use diffuse_scene::physics::queries::physics_query_types::{
    PhysicsOverlapAABBQuery, PhysicsOverlapShapeQuery, PhysicsQueryFilter, PhysicsQueryShape,
    PhysicsRaycastQuery, PhysicsSweepAABBQuery, PhysicsSweepShapeQuery,
};
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::core::script_runtime::ScriptRuntime;

/// Swift's `SceneRuntime()`; the Rust runtime takes its component registry.
fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

/// A `0.5`-half-extent box collider on the given layer bits.
fn box_collider(is_trigger: bool) -> Collider {
    let mut collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::new(0.5, 0.5, 0.5),
        center: Float3::ZERO,
    });
    collider.is_trigger = is_trigger;
    collider.layer_id = 1;
    collider.layer_mask = 0b0010;
    collider
}

/// `PhysicsQueryFilter(layerID:layerMask:)` with Swift's other defaults.
fn layer_filter() -> PhysicsQueryFilter {
    PhysicsQueryFilter::with_options(None, BTreeSet::new(), false, Some(1), 0b0010)
}

/// `PhysicsQueryFilter(includeTriggers:layerID:layerMask:)`.
fn trigger_filter() -> PhysicsQueryFilter {
    PhysicsQueryFilter::with_options(None, BTreeSet::new(), true, Some(1), 0b0010)
}

/// `ScriptRuntime forwards physics raycasts with unified filters`
#[test]
fn script_runtime_forwards_physics_raycasts() {
    let mut runtime = scene();
    let script_runtime = ScriptRuntime::new();

    let excluded = runtime.create_entity();
    runtime.set_local_transform(
        diffuse_scene::runtime_world::LocalTransform::from_translation(Float3::new(1.0, 0.0, 0.0)),
        excluded,
    );
    runtime.set_component(box_collider(false), excluded);

    let target = runtime.create_entity();
    runtime.set_local_transform(
        diffuse_scene::runtime_world::LocalTransform::from_translation(Float3::new(4.0, 0.0, 0.0)),
        target,
    );
    runtime.set_component(box_collider(false), target);

    runtime.tick(0.0, 0, Vec::new());

    let hit = script_runtime.physics_raycast(
        &mut runtime,
        PhysicsRaycastQuery::with_distance(
            Float3::new(-5.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            20.0,
        ),
        PhysicsQueryFilter::with_options(Some(excluded), BTreeSet::new(), false, Some(1), 0b0010),
    );

    assert_eq!(hit.map(|hit| hit.entity), Some(target));
}

/// `ScriptRuntime forwards physics overlap and sweep queries`
#[test]
fn script_runtime_forwards_overlap_and_sweep_queries() {
    let mut runtime = scene();
    let script_runtime = ScriptRuntime::new();

    let trigger = runtime.create_entity();
    runtime.set_local_transform(
        diffuse_scene::runtime_world::LocalTransform::from_translation(Float3::new(2.0, 0.0, 0.0)),
        trigger,
    );
    runtime.set_component(box_collider(true), trigger);

    let solid = runtime.create_entity();
    runtime.set_local_transform(
        diffuse_scene::runtime_world::LocalTransform::from_translation(Float3::new(4.0, 0.0, 0.0)),
        solid,
    );
    runtime.set_component(box_collider(false), solid);

    runtime.tick(0.0, 0, Vec::new());

    let overlap_hits = script_runtime.physics_overlap_aabb(
        &mut runtime,
        PhysicsOverlapAABBQuery::new(SpatialAABB::from_center_half_extents(
            Float3::new(3.0, 0.0, 0.0),
            Float3::new(2.0, 1.0, 1.0),
        )),
        layer_filter(),
    );
    let sweep_hit = script_runtime.physics_sweep_aabb(
        &mut runtime,
        PhysicsSweepAABBQuery::new(
            SpatialAABB::from_center_half_extents(Float3::ZERO, Float3::new(0.5, 0.5, 0.5)),
            Float3::new(10.0, 0.0, 0.0),
        ),
        trigger_filter(),
    );
    let shape_overlap_hits = script_runtime.physics_overlap_shape(
        &mut runtime,
        PhysicsOverlapShapeQuery::new(
            PhysicsQueryShape::Sphere { radius: 1.25 },
            Float3::new(4.0, 0.0, 0.0),
        ),
        layer_filter(),
    );
    let shape_sweep_hit = script_runtime.physics_sweep_shape(
        &mut runtime,
        PhysicsSweepShapeQuery::new(
            PhysicsQueryShape::Sphere { radius: 0.5 },
            Float3::ZERO,
            Float3::new(10.0, 0.0, 0.0),
        ),
        trigger_filter(),
    );

    assert_eq!(
        overlap_hits
            .iter()
            .map(|hit| hit.entity)
            .collect::<Vec<_>>(),
        vec![solid]
    );
    assert_eq!(sweep_hit.map(|hit| hit.entity), Some(trigger));
    assert_eq!(sweep_hit.map(|hit| hit.is_trigger), Some(true));
    assert_eq!(
        shape_overlap_hits
            .iter()
            .map(|hit| hit.entity)
            .collect::<Vec<_>>(),
        vec![solid]
    );
    assert_eq!(shape_sweep_hit.map(|hit| hit.entity), Some(trigger));
    assert_eq!(shape_sweep_hit.map(|hit| hit.is_trigger), Some(true));
}
