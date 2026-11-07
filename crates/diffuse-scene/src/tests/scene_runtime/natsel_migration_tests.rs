//! Ported from `Engine/Tests/SceneRuntimeTests/NatselMigrationTests.swift`.
//!
//! Swift's `tick(deltaTime:)` has no frame index, so every call here passes the
//! frame that Swift's `frameIndex` argument would have (0 unless the case is
//! explicitly about a frame). Colliders with defaulted arguments (`isTrigger`,
//! `layerMask`) are built through `with_shape` and then field-assigned.

use diffuse_math::simd::simd_compat::{Float3, Float4};

use crate::components::core::registry::ComponentRegistry;
use crate::entity_id::EntityID;
use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;
use crate::physics::character_controller::CharacterController;
use crate::physics::collider::{Collider, ColliderShape, ColliderShapeInstance, SpatialAABB};
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::physics_types::PhysicsSimulationMode;
use crate::physics::queries::physics_query_types::{
    PhysicsOverlapAABBQuery, PhysicsQueryFilter, PhysicsQueryShape, PhysicsRaycastQuery,
    PhysicsSweepShapeQuery,
};
use crate::physics::queries::trigger_detection::TriggerEventKind;
use crate::physics::rigid_body::{RigidBody, RigidBodyOptions};
use crate::runtime_world::LocalTransform;
use crate::scene_runtime::SceneRuntime;

fn make_scene(backend: PhysicsBackendKind) -> SceneRuntime {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        backend_kind: backend,
        gravity: Float3::ZERO,
        fixed_time_step_seconds: 1.0 / 60.0,
        max_substeps_per_frame: 1,
        allow_sleep: false,
        ..PhysicsSettingsResource::default()
    });
    runtime
}

fn sphere(radius: f32) -> ColliderShape {
    ColliderShape::Sphere {
        radius,
        center: Float3::ZERO,
    }
}

fn ray(origin: Float3, direction: Float3, max_distance: f32) -> PhysicsRaycastQuery {
    PhysicsRaycastQuery::with_distance(origin, direction, max_distance)
}

/// Disabling and re-enabling physics rebuilds queries from the current ECS state.
#[test]
fn switches_backend_without_losing_bodies() {
    let mut runtime = make_scene(PhysicsBackendKind::Natsel);
    let entity = runtime.create_entity();
    runtime.set_component(Collider::with_shape(sphere(0.5)), entity);
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            linear_velocity: Float3::new(6.0, 0.0, 0.0),
            allow_sleep: false,
            ..RigidBodyOptions::default()
        }),
        entity,
    );

    let mut previous_x: f32 = 0.0;
    for backend in [
        PhysicsBackendKind::Natsel,
        PhysicsBackendKind::None,
        PhysicsBackendKind::Natsel,
    ] {
        let mut settings = runtime.physics_settings();
        settings.backend_kind = backend;
        runtime.set_physics_settings(settings);

        let report = runtime.tick(1.0 / 60.0, 0, Vec::new());
        assert!(report.physics.error.is_none());
        assert_eq!(report.physics.backend_identifier, backend.raw_value());

        let x = runtime
            .world_transform(entity)
            .map(|transform| transform.translation().x)
            .unwrap_or(0.0);
        if backend == PhysicsBackendKind::None {
            assert_eq!(x.partial_cmp(&previous_x), Some(std::cmp::Ordering::Equal));
            continue;
        }
        assert!(x > previous_x + 0.09);
        previous_x = x;

        let hit = runtime.physics_raycast(
            ray(Float3::new(x, 0.0, -2.0), Float3::new(0.0, 0.0, 1.0), 4.0),
            PhysicsQueryFilter::default(),
        );
        assert_eq!(hit.map(|hit| hit.entity), Some(entity));
    }
}

/// Editing a moving compound replaces child geometry and preserves motion.
#[test]
fn edits_dynamic_compound() {
    let mut runtime = make_scene(PhysicsBackendKind::Natsel);
    let entity = runtime.create_entity();
    runtime.set_component(
        Collider::with_shapes(vec![ColliderShapeInstance::with_transform(
            sphere(0.25),
            Float3::new(-2.0, 0.0, 0.0),
            Float4::new(0.0, 0.0, 0.0, 1.0),
            Float3::ONE,
        )]),
        entity,
    );
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            linear_velocity: Float3::new(0.0, 1.0, 0.0),
            allow_sleep: false,
            ..RigidBodyOptions::default()
        }),
        entity,
    );
    runtime.tick(1.0 / 60.0, 0, Vec::new());
    runtime.update_component::<Collider>(entity, |collider| {
        collider.shapes[0].local_position.x = 2.0;
    });

    let report = runtime.tick(1.0 / 60.0, 0, Vec::new());
    assert!(report.physics.error.is_none());
    assert_eq!(report.physics.body_count, 1);
    assert!(
        runtime
            .world_transform(entity)
            .map(|transform| transform.translation().y)
            .unwrap_or(0.0)
            > 0.03
    );

    let ray_at = |x: f32| ray(Float3::new(x, 0.0, -2.0), Float3::new(0.0, 0.0, 1.0), 4.0);
    assert!(
        runtime
            .physics_raycast(ray_at(-2.0), PhysicsQueryFilter::default())
            .is_none()
    );
    assert_eq!(
        runtime
            .physics_raycast(ray_at(2.0), PhysicsQueryFilter::default())
            .map(|hit| hit.entity),
        Some(entity)
    );
}

/// Limited overlaps select entities in stable order across geometry rebuilds.
#[test]
fn limited_overlaps_are_stable() {
    let mut runtime = make_scene(PhysicsBackendKind::Natsel);
    let mut entities: Vec<EntityID> = Vec::new();
    for _ in 0..4 {
        entities.push(runtime.create_entity());
    }
    for entity in entities.iter().rev() {
        runtime.set_component(Collider::with_shape(sphere(0.5)), *entity);
    }

    let query = PhysicsOverlapAABBQuery::with_max_results(
        SpatialAABB::from_center_half_extents(Float3::ZERO, Float3::splat(2.0)),
        2,
    );
    let first: Vec<EntityID> = runtime
        .physics_overlap_aabb(query, PhysicsQueryFilter::default())
        .into_iter()
        .map(|hit| hit.entity)
        .collect();
    assert_eq!(first, entities[..2].to_vec());

    runtime.update_component::<Collider>(entities[0], |collider| {
        collider.set_shape(sphere(0.6));
    });
    let second: Vec<EntityID> = runtime
        .physics_overlap_aabb(query, PhysicsQueryFilter::default())
        .into_iter()
        .map(|hit| hit.entity)
        .collect();
    assert_eq!(second, entities[..2].to_vec());
}

/// Virtual characters emit trigger enter and exit events in play mode.
#[test]
fn character_triggers() {
    let mut runtime = make_scene(PhysicsBackendKind::Natsel);
    let trigger = runtime.create_entity();
    let mut trigger_collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::new(1.0, 2.0, 1.0),
        center: Float3::ZERO,
    });
    trigger_collider.is_trigger = true;
    runtime.set_component(trigger_collider, trigger);

    let character = runtime.create_entity();
    let controller = CharacterController {
        gravity_scale: 0.0,
        ..Default::default()
    };
    runtime.set_component(controller, character);

    let first = runtime.tick(1.0 / 60.0, 0, Vec::new());
    assert!(first.physics.error.is_none());
    assert!(
        runtime
            .physics_event_frame()
            .triggers
            .iter()
            .any(|event| event.trigger_entity == trigger
                && event.other_entity == character
                && event.kind == TriggerEventKind::Enter)
    );

    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(5.0, 0.0, 0.0)),
        character,
    );
    runtime.tick(1.0 / 60.0, 1, Vec::new());
    assert!(
        runtime
            .physics_event_frame()
            .triggers
            .iter()
            .any(|event| event.trigger_entity == trigger
                && event.other_entity == character
                && event.kind == TriggerEventKind::Exit)
    );
}

/// Multiple fixed substeps accumulate gravity and consume impulses once.
#[test]
fn fixed_substeps() {
    let mut runtime = make_scene(PhysicsBackendKind::Natsel);
    let mut settings = runtime.physics_settings();
    settings.gravity = Float3::new(0.0, -6.0, 0.0);
    settings.max_substeps_per_frame = 4;
    runtime.set_physics_settings(settings);

    let entity = runtime.create_entity();
    runtime.set_component(Collider::with_shape(sphere(0.5)), entity);
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            mass: 1.0,
            accumulated_linear_impulse: Float3::new(1.0, 0.0, 0.0),
            linear_damping: 0.0,
            angular_damping: 0.0,
            allow_sleep: false,
            ..RigidBodyOptions::default()
        }),
        entity,
    );

    let report = runtime.tick(1.0 / 30.0, 0, Vec::new());
    assert!(report.physics.error.is_none());
    assert_eq!(report.physics.step_count, 2);
    let velocity = runtime
        .component::<RigidBody>(entity)
        .map(|body| body.linear_velocity)
        .unwrap_or(Float3::ZERO);
    assert!((velocity.x - 1.0).abs() < 0.001);
    assert!((velocity.y + 0.2).abs() < 0.001);
}

/// Sweeps do not report a contact beyond the requested translation.
#[test]
fn sweep_endpoint() {
    let mut runtime = make_scene(PhysicsBackendKind::Natsel);
    let entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(2.003, 0.0, 0.0)),
        entity,
    );
    runtime.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::splat(0.5),
            center: Float3::ZERO,
        }),
        entity,
    );
    runtime.tick(0.0, 0, Vec::new());

    let hit = runtime.physics_sweep_shape(
        PhysicsSweepShapeQuery::new(
            PhysicsQueryShape::Box {
                half_extents: Float3::splat(0.5),
            },
            Float3::ZERO,
            Float3::new(1.0, 0.0, 0.0),
        ),
        PhysicsQueryFilter::default(),
    );
    assert!(hit.is_none());
}

/// Scene queries consistently exclude geometry with an empty collision mask.
#[test]
fn queries_without_physical_collisions() {
    let mut runtime = make_scene(PhysicsBackendKind::Natsel);
    let entity = runtime.create_entity();
    let mut collider = Collider::with_shape(sphere(0.5));
    collider.layer_mask = 0;
    runtime.set_component(collider, entity);
    runtime.tick(0.0, 0, Vec::new());

    let ray_query = ray(Float3::new(0.0, 0.0, -2.0), Float3::new(0.0, 0.0, 1.0), 4.0);
    assert!(
        runtime
            .physics_raycast(ray_query, PhysicsQueryFilter::default())
            .is_none()
    );
    assert!(
        runtime
            .physics_raycast(
                ray_query,
                PhysicsQueryFilter {
                    layer_id: Some(0),
                    ..PhysicsQueryFilter::default()
                },
            )
            .is_none()
    );

    let overlap = PhysicsOverlapAABBQuery::new(SpatialAABB::from_center_half_extents(
        Float3::ZERO,
        Float3::splat(1.0),
    ));
    assert!(
        runtime
            .physics_overlap_aabb(overlap, PhysicsQueryFilter::default())
            .is_empty()
    );
}
