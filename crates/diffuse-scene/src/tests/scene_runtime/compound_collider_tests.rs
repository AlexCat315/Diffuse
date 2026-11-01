//! Ported from `Engine/Tests/SceneRuntimeTests/CompoundColliderTests.swift`.
//!
//! Swift's `raycast(_:options:)` / `shapeCast(_:options:)` are `raycast_all_options`
//! and `shape_cast` in Rust; `physicsRaycast(_:)` is `physics_raycast` with an
//! explicit filter.

use std::collections::BTreeSet;

use diffuse_math::simd::simd_compat::{Float3, Float4};

use crate::components::core::registry::ComponentRegistry;
use crate::physics::collider::{Collider, ColliderShape, ColliderShapeInstance, PhysicsMaterial};
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::physics_types::{PhysicsBackendErrorCode, PhysicsSimulationMode};
use crate::physics::queries::physics_query_types::{
    PhysicsQueryFilter, PhysicsQueryOptions, PhysicsQueryResultMode, PhysicsQueryShape,
    PhysicsRaycastQuery, PhysicsSweepShapeQuery,
};
use crate::runtime_world::LocalTransform;
use crate::scene_runtime::SceneRuntime;
use crate::serialization::scene_serializer::SceneSerializer;

const DELTA_TIME: f64 = 1.0 / 60.0;

fn compound_collider() -> Collider {
    let mut collider = Collider::with_shapes(vec![
        ColliderShapeInstance::with_transform(
            ColliderShape::Box {
                half_extents: Float3::splat(0.5),
                center: Float3::ZERO,
            },
            Float3::new(-2.0, 0.0, 0.0),
            Float4::new(0.0, 0.0, 0.0, 1.0),
            Float3::ONE,
        ),
        ColliderShapeInstance::with_transform(
            ColliderShape::Cylinder {
                radius: 0.5,
                half_height: 0.75,
                center: Float3::ZERO,
            },
            Float3::new(2.0, 0.0, 0.0),
            Float4::new(0.0, 0.0, 0.0, 1.0),
            Float3::new(1.0, 1.5, 1.0),
        ),
    ]);
    collider.layer_id = 2;
    collider.layer_mask = 0x00FF;
    collider.material = PhysicsMaterial::new(0.4, 0.2, 3.0);
    collider
}

fn raycast(origin: Float3, direction: Float3, max_distance: f32) -> PhysicsRaycastQuery {
    PhysicsRaycastQuery::with_distance(origin, direction, max_distance)
}

/// Natsel queries every child of a compound collider.
#[test]
fn native_compound_shape() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, entity);
    runtime.set_component(compound_collider(), entity);

    let left = runtime.physics_raycast(
        raycast(
            Float3::new(-2.0, 0.0, -4.0),
            Float3::new(0.0, 0.0, 1.0),
            8.0,
        ),
        PhysicsQueryFilter::default(),
    );
    let right = runtime.physics_raycast(
        raycast(
            Float3::new(2.0, 0.0, -4.0),
            Float3::new(0.0, 0.0, 1.0),
            8.0,
        ),
        PhysicsQueryFilter::default(),
    );
    let gap = runtime.physics_raycast(
        raycast(Float3::new(0.0, 0.0, -4.0), Float3::new(0.0, 0.0, 1.0), 8.0),
        PhysicsQueryFilter::default(),
    );

    assert_eq!(left.map(|hit| hit.entity), Some(entity));
    assert_eq!(right.map(|hit| hit.entity), Some(entity));
    assert!(gap.is_none());
}

/// Scene v3 preserves compound local transforms.
#[test]
fn serialization_round_trip() {
    let compound = compound_collider();
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, entity);
    runtime.set_component(compound.clone(), entity);

    let data = SceneSerializer::serialize(runtime.world()).expect("serialize");
    let mut restored = SceneRuntime::new(ComponentRegistry::built_in());
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");
    let restored_entity = restored.entities().first().copied().expect("entity");
    assert_eq!(
        restored.component::<Collider>(restored_entity),
        Some(compound)
    );
}

/// Empty compounds report an explicit native error.
#[test]
fn empty_compound_fails() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        ..PhysicsSettingsResource::default()
    });
    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, entity);
    runtime.set_component(Collider::with_shapes(Vec::new()), entity);
    let report = runtime.tick(DELTA_TIME, 0, Vec::new());
    assert_eq!(
        report.physics.error.as_ref().map(|error| error.code),
        Some(PhysicsBackendErrorCode::InvalidShape)
    );
}

/// Unified queries return stable all-hit ordering.
#[test]
fn unified_all_hits() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    let mut expected = Vec::new();
    for z in [1.0f32, 4.0, 7.0] {
        let entity = runtime.create_entity();
        expected.push(entity);
        runtime.set_local_transform(
            LocalTransform::from_translation(Float3::new(0.0, 0.0, z)),
            entity,
        );
        runtime.set_component(
            Collider::with_shape(ColliderShape::Box {
                half_extents: Float3::splat(0.5),
                center: Float3::ZERO,
            }),
            entity,
        );
    }

    let options = PhysicsQueryOptions {
        result_mode: PhysicsQueryResultMode::All,
        ..PhysicsQueryOptions::default()
    };
    let hits = runtime.raycast_all_options(
        raycast(Float3::new(0.0, 0.0, -2.0), Float3::new(0.0, 0.0, 1.0), 12.0),
        options.clone(),
    );
    assert_eq!(
        hits.iter().map(|hit| hit.entity).collect::<Vec<_>>(),
        expected
    );
    let distances: Vec<f32> = hits.iter().map(|hit| hit.distance).collect();
    let mut sorted = distances.clone();
    sorted.sort_by(|left, right| left.partial_cmp(right).expect("finite distance"));
    assert_eq!(distances, sorted);

    let cast_hits = runtime.shape_cast(
        PhysicsSweepShapeQuery::new(
            PhysicsQueryShape::Sphere { radius: 0.25 },
            Float3::new(0.0, 0.0, -2.0),
            Float3::new(0.0, 0.0, 12.0),
        ),
        options,
    );
    assert_eq!(
        cast_hits
            .iter()
            .map(|hit| hit.entity)
            .collect::<Vec<_>>(),
        expected
    );
}

/// Unified queries ignore entity sets and support batches.
#[test]
fn ignored_entity_sets_and_batches() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    let mut entities = Vec::new();
    for z in [1.0f32, 4.0, 7.0] {
        let entity = runtime.create_entity();
        entities.push(entity);
        runtime.set_local_transform(
            LocalTransform::from_translation(Float3::new(0.0, 0.0, z)),
            entity,
        );
        runtime.set_component(
            Collider::with_shape(ColliderShape::Sphere {
                radius: 0.5,
                center: Float3::ZERO,
            }),
            entity,
        );
    }

    let options = PhysicsQueryOptions {
        filter: PhysicsQueryFilter {
            ignored_entities: entities
                .iter()
                .take(2)
                .copied()
                .collect::<BTreeSet<_>>(),
            ..PhysicsQueryFilter::default()
        },
        result_mode: PhysicsQueryResultMode::Nearest,
        ..PhysicsQueryOptions::default()
    };
    let query = raycast(
        Float3::new(0.0, 0.0, -2.0),
        Float3::new(0.0, 0.0, 1.0),
        12.0,
    );
    assert_eq!(
        runtime
            .raycast_all_options(query, options.clone())
            .iter()
            .map(|hit| hit.entity)
            .collect::<Vec<_>>(),
        vec![entities[2]]
    );

    let batches = runtime.raycast_batch(
        vec![
            query,
            raycast(
                Float3::new(10.0, 0.0, -2.0),
                Float3::new(0.0, 0.0, 1.0),
                12.0,
            ),
        ],
        options,
    );
    assert_eq!(batches.len(), 2);
    assert_eq!(
        batches[0]
            .iter()
            .map(|hit| hit.entity)
            .collect::<Vec<_>>(),
        vec![entities[2]]
    );
    assert!(batches[1].is_empty());
}

/// Play-mode sensors are emitted by the contact listener.
#[test]
fn native_sensor_events() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        ..PhysicsSettingsResource::default()
    });
    let trigger = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, trigger);
    let mut trigger_collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::splat(1.0),
        center: Float3::ZERO,
    });
    trigger_collider.is_trigger = true;
    runtime.set_component(trigger_collider, trigger);

    let other = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, other);
    runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.25,
            center: Float3::ZERO,
        }),
        other,
    );

    runtime.tick(DELTA_TIME, 0, Vec::new());
    let events = runtime.physics_event_frame();
    assert!(events.triggers.iter().any(|event| {
        event.trigger_entity == trigger
            && event.other_entity == other
            && event.kind == crate::physics::queries::trigger_detection::TriggerEventKind::Enter
    }));
    assert!(events.contacts.is_empty());
}
