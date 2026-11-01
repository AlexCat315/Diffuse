//! Ported from `Engine/Tests/SceneRuntimeTests/AdvancedRigidBodyTests.swift`.
//!
//! Swift's `tick(deltaTime:)` has no frame index; the Rust schedule takes one plus
//! the frame's input events, so every call here advances the index by one and
//! supplies no input.

use diffuse_math::simd::simd_compat::Float3;

use crate::components::core::registry::ComponentRegistry;
use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;
use crate::physics::collider::{Collider, ColliderShape};
use crate::physics::physics_settings::{PhysicsCapacitySettings, PhysicsSettingsResource};
use crate::physics::physics_types::PhysicsSimulationMode;
use crate::physics::queries::physics_query_types::{PhysicsQueryFilter, PhysicsRaycastQuery};
use crate::physics::rigid_body::{
    PhysicsKinematicTarget, RigidBody, RigidBodyAxisLocks, RigidBodyMotionType, RigidBodyOptions,
};
use crate::runtime_world::LocalTransform;
use crate::scene_runtime::SceneRuntime;

const DELTA_TIME: f64 = 1.0 / 60.0;

fn runtime() -> SceneRuntime {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        max_substeps_per_frame: 1,
        ..PhysicsSettingsResource::default()
    });
    runtime
}

fn tick(runtime: &mut SceneRuntime, frame: u64) -> crate::scheduling::schedule_report::RuntimeScheduleReport {
    runtime.tick(DELTA_TIME, frame, Vec::new())
}

/// Axis locks and the maximum velocity limit reach the selected backend.
#[test]
fn locks_and_velocity_limit() {
    let mut runtime = runtime();
    let entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 3.0, 0.0)),
        entity,
    );
    runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        entity,
    );
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            linear_velocity: Float3::new(100.0, 0.0, 0.0),
            axis_locks: RigidBodyAxisLocks::TRANSLATION_Y,
            max_linear_velocity: 2.0,
            ..RigidBodyOptions::default()
        }),
        entity,
    );

    tick(&mut runtime, 0);
    let body = runtime.component::<RigidBody>(entity);
    assert!(
        body.map(|body| body.linear_velocity.x.abs())
            .unwrap_or(0.0)
            <= 2.01
    );
    assert!(
        (runtime
            .world_transform(entity)
            .map(|transform| transform.translation().y)
            .unwrap_or(0.0)
            - 3.0)
            .abs()
            < 0.001
    );
}

/// A kinematic target is solved over the fixed step.
#[test]
fn kinematic_target() {
    let mut runtime = runtime();
    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, entity);
    runtime.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::splat(0.5),
            center: Float3::ZERO,
        }),
        entity,
    );
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            motion_type: RigidBodyMotionType::Kinematic,
            kinematic_target: Some(PhysicsKinematicTarget::new(Float3::new(3.0, 0.0, 0.0))),
            ..RigidBodyOptions::default()
        }),
        entity,
    );

    tick(&mut runtime, 0);
    assert!(
        (runtime
            .world_transform(entity)
            .map(|transform| transform.translation().x)
            .unwrap_or(0.0)
            - 3.0)
            .abs()
            < 0.01
    );
}

/// A point impulse produces both linear and angular response.
#[test]
fn point_impulse() {
    let mut runtime = runtime();
    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, entity);
    runtime.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::splat(0.5),
            center: Float3::ZERO,
        }),
        entity,
    );
    runtime.set_component(RigidBody::default(), entity);
    let applied = runtime.apply_linear_impulse_at(
        Float3::new(2.0, 0.0, 0.0),
        Float3::new(0.0, 1.0, 0.0),
        entity,
        true,
    );
    assert!(applied);

    tick(&mut runtime, 0);
    let body = runtime.component::<RigidBody>(entity).expect("rigid body");
    assert!(body.linear_velocity.x > 0.0);
    assert!(body.angular_velocity.z < 0.0);
}

/// Unchanged rigid bodies do not produce ECS writebacks.
#[test]
fn unchanged_body_skips_writeback() {
    let mut runtime = runtime();
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        gravity: Float3::ZERO,
        max_substeps_per_frame: 1,
        allow_sleep: false,
        ..PhysicsSettingsResource::default()
    });
    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, entity);
    runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        entity,
    );
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            motion_type: RigidBodyMotionType::Dynamic,
            gravity_scale: 0.0,
            allow_sleep: false,
            ..RigidBodyOptions::default()
        }),
        entity,
    );

    let report = tick(&mut runtime, 0);
    assert_eq!(report.physics.body_count, 1);
    assert_eq!(report.physics.writeback_count, 0);
    assert_eq!(runtime.physics_frame_state().active_body_count, 1);
}

/// Independent, same-build simulations produce identical state hashes.
#[test]
fn deterministic_state_hashes() {
    fn make_runtime() -> SceneRuntime {
        let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
        runtime.set_physics_settings(PhysicsSettingsResource {
            simulation_mode: PhysicsSimulationMode::Play,
            max_substeps_per_frame: 1,
            allow_sleep: false,
            ..PhysicsSettingsResource::default()
        });
        let ground = runtime.create_entity();
        runtime.set_local_transform(
            LocalTransform::from_translation(Float3::new(0.0, -1.0, 0.0)),
            ground,
        );
        runtime.set_component(
            Collider::with_shape(ColliderShape::Box {
                half_extents: Float3::new(5.0, 0.5, 5.0),
                center: Float3::ZERO,
            }),
            ground,
        );
        for index in 0..8usize {
            let body = runtime.create_entity();
            runtime.set_local_transform(
                LocalTransform::from_translation(Float3::new(
                    (index % 2) as f32 * 0.8,
                    1.0 + index as f32 * 1.1,
                    (index / 2) as f32 * 0.1,
                )),
                body,
            );
            runtime.set_component(
                Collider::with_shape(ColliderShape::Box {
                    half_extents: Float3::splat(0.35),
                    center: Float3::ZERO,
                }),
                body,
            );
            runtime.set_component(
                RigidBody::new(RigidBodyOptions {
                    allow_sleep: false,
                    ..RigidBodyOptions::default()
                }),
                body,
            );
        }
        runtime
    }

    let mut first = make_runtime();
    let mut second = make_runtime();
    for frame in 0..120u64 {
        tick(&mut first, frame);
        tick(&mut second, frame);
        assert_eq!(
            first.physics_state_hash_frame(),
            second.physics_state_hash_frame()
        );
    }
    assert_ne!(first.physics_state_hash_frame().hash, 0);
}

/// Capacity settings create and safely rebuild the native context.
#[test]
fn capacity_settings_rebuild_context() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    let initial_capacity = PhysicsCapacitySettings::new(64, 1);
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        backend_kind: PhysicsBackendKind::Natsel,
        max_substeps_per_frame: 1,
        allow_sleep: false,
        capacity: initial_capacity,
        ..PhysicsSettingsResource::default()
    });
    let entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 3.0, 0.0)),
        entity,
    );
    runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        entity,
    );
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            allow_sleep: false,
            ..RigidBodyOptions::default()
        }),
        entity,
    );

    let first = tick(&mut runtime, 0);
    let first_y = runtime
        .world_transform(entity)
        .map(|transform| transform.translation().y)
        .unwrap_or(3.0);
    assert!(first.physics.error.is_none());
    assert_eq!(first.physics.body_count, 1);

    let mut settings = runtime.physics_settings();
    settings.capacity.max_bodies = 128;
    settings.capacity.worker_thread_count = 2;
    runtime.set_physics_settings(settings);
    let second = tick(&mut runtime, 1);
    let second_y = runtime
        .world_transform(entity)
        .map(|transform| transform.translation().y)
        .unwrap_or(3.0);
    assert!(second.physics.error.is_none());
    assert_eq!(second.physics.body_count, 1);
    assert!(second_y < first_y);
}

/// Recorded physics commands replay to identical checkpoint hashes.
#[test]
fn command_recording_replay() {
    fn make_runtime() -> (SceneRuntime, crate::entity_id::EntityID) {
        let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
        runtime.set_physics_settings(PhysicsSettingsResource {
            simulation_mode: PhysicsSimulationMode::Play,
            gravity: Float3::ZERO,
            max_substeps_per_frame: 1,
            allow_sleep: false,
            capacity: PhysicsCapacitySettings::new(
                PhysicsCapacitySettings::default().max_bodies,
                1,
            ),
            ..PhysicsSettingsResource::default()
        });
        let entity = runtime.create_entity();
        runtime.set_local_transform(LocalTransform::IDENTITY, entity);
        runtime.set_component(
            Collider::with_shape(ColliderShape::Sphere {
                radius: 0.5,
                center: Float3::ZERO,
            }),
            entity,
        );
        runtime.set_component(
            RigidBody::new(RigidBodyOptions {
                gravity_scale: 0.0,
                allow_sleep: false,
                ..RigidBodyOptions::default()
            }),
            entity,
        );
        (runtime, entity)
    }

    let (mut recording, recorded_entity) = make_runtime();
    recording.begin_physics_command_recording(120);
    for frame in 0..60u64 {
        if frame == 0 {
            recording.apply_linear_impulse(Float3::new(2.0, 0.5, 0.0), recorded_entity, true);
        }
        if frame % 10 == 0 {
            recording.apply_force(Float3::new(0.0, 1.0, 0.25), recorded_entity, true);
        }
        tick(&mut recording, frame);
    }
    let tape = recording.end_physics_command_recording();
    let expected_transform = recording.world_transform(recorded_entity);
    assert_eq!(tape.frames.len(), 60);

    let (mut replay_runtime, replay_entity) = make_runtime();
    let replay = replay_runtime.replay_physics_commands(&tape);
    assert!(replay.is_deterministic());
    assert_eq!(replay.replayed_frame_count, 60);
    assert_eq!(replay_runtime.world_transform(replay_entity), expected_transform);
}

/// Native synchronization sends only authored or commanded body changes.
#[test]
fn incremental_native_synchronization() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        gravity: Float3::ZERO,
        max_substeps_per_frame: 1,
        allow_sleep: false,
        capacity: PhysicsCapacitySettings::new(
            PhysicsCapacitySettings::default().max_bodies,
            1,
        ),
        ..PhysicsSettingsResource::default()
    });
    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, entity);
    runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        entity,
    );
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            linear_velocity: Float3::new(1.0, 0.0, 0.0),
            gravity_scale: 0.0,
            allow_sleep: false,
            ..RigidBodyOptions::default()
        }),
        entity,
    );

    tick(&mut runtime, 0);
    assert_eq!(runtime.physics_frame_state().synchronization.bodies, 1);

    tick(&mut runtime, 1);
    assert_eq!(runtime.physics_frame_state().synchronization.bodies, 0);

    runtime.apply_force(Float3::new(0.0, 2.0, 0.0), entity, true);
    tick(&mut runtime, 2);
    assert_eq!(runtime.physics_frame_state().synchronization.bodies, 1);

    tick(&mut runtime, 3);
    assert_eq!(runtime.physics_frame_state().synchronization.bodies, 0);

    let destroyed = runtime.destroy_entity(entity);
    assert!(destroyed);
    tick(&mut runtime, 4);
    assert_eq!(
        runtime.physics_raycast(
            PhysicsRaycastQuery::with_distance(
                Float3::new(-5.0, 0.0, 0.0),
                Float3::new(1.0, 0.0, 0.0),
                10.0,
            ),
            PhysicsQueryFilter::default(),
        ),
        None
    );
}
