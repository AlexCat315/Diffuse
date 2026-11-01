//! Ported from `Engine/Tests/SceneRuntimeTests/PhysicsBackendSelectionTests.swift`.
//!
//! Backend-selection coverage: the authored `backendKind` decides which backend
//! runs, an explicit override still wins, and the selected Natsel backend really
//! writes body state, contacts and joint responses back into the `SceneRuntime`.

use std::sync::{Arc, Mutex};

use diffuse_math::simd::simd_compat::{
    Float3, MATRIX_IDENTITY_FLOAT4X4, Quatf, simd_dot4, simd_length,
};

use crate::components::core::registry::ComponentRegistry;
use crate::entity_id::EntityID;
use crate::physics::backend::physics_backend::PhysicsBackend;
use crate::physics::backend::physics_backend_capabilities::PhysicsBackendCapabilities;
use crate::physics::backend::physics_backend_context::{
    PhysicsPrepareContext, PhysicsPrepareResult, PhysicsStepContext, PhysicsStepResult,
};
use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;
use crate::physics::collider::{Collider, ColliderShape, PhysicsMaterial};
use crate::physics::joints::physics_joint::PhysicsJoint;
use crate::physics::joints::physics_joint_configuration::PhysicsJointKind;
use crate::physics::physics_events::PhysicsContactEvent;
use crate::physics::physics_settings::{PhysicsCapacitySettings, PhysicsSettingsResource};
use crate::physics::physics_types::PhysicsSimulationMode;
use crate::physics::queries::physics_query_types::{
    PhysicsOverlapAABBQuery, PhysicsOverlapHit, PhysicsOverlapShapeQuery, PhysicsQueryFilter,
    PhysicsRaycastHit, PhysicsRaycastQuery, PhysicsSweepAABBQuery, PhysicsSweepHit,
    PhysicsSweepShapeQuery,
};
use crate::physics::queries::trigger_detection::TriggerFrameResource;
use crate::physics::rigid_body::{RigidBody, RigidBodyMotionType, RigidBodyOptions};
use crate::runtime_world::LocalTransform;
use crate::scene_runtime::SceneRuntime;
use crate::scheduling::schedule_report::RuntimeScheduleReport;

/// Swift `SelectionRecordingPhysicsBackend`: reports its identifier, records every
/// prepare context and otherwise simulates nothing.
struct SelectionRecordingPhysicsBackend {
    prepare_contexts: Arc<Mutex<Vec<PhysicsPrepareContext>>>,
    capabilities: PhysicsBackendCapabilities,
}

impl SelectionRecordingPhysicsBackend {
    fn new() -> Self {
        SelectionRecordingPhysicsBackend {
            prepare_contexts: Arc::new(Mutex::new(Vec::new())),
            capabilities: PhysicsBackendCapabilities::all(),
        }
    }

    /// The shared capture queue, so a test can still read it after the backend has
    /// been moved into the runtime.
    fn capture_queue(&self) -> Arc<Mutex<Vec<PhysicsPrepareContext>>> {
        Arc::clone(&self.prepare_contexts)
    }
}

impl PhysicsBackend for SelectionRecordingPhysicsBackend {
    fn identifier(&self) -> &str {
        "recording"
    }

    fn capabilities(&self) -> PhysicsBackendCapabilities {
        self.capabilities
    }

    fn prepare(&mut self, context: PhysicsPrepareContext) -> PhysicsPrepareResult {
        self.prepare_contexts
            .lock()
            .expect("prepare context queue")
            .push(context.clone());
        PhysicsPrepareResult {
            synchronized_bodies: context.active_bodies.len() as i64,
            synchronized_constraints: context.active_constraints.len() as i64,
            ..PhysicsPrepareResult::default()
        }
    }

    fn step(&mut self, context: PhysicsStepContext) -> PhysicsStepResult {
        PhysicsStepResult {
            body_count: context.active_bodies.len() as i64,
            constraint_count: context.active_constraints.len() as i64,
            contact_count: 0,
            writebacks: Vec::new(),
            ..PhysicsStepResult::default()
        }
    }

    fn raycast(
        &self,
        _query: PhysicsRaycastQuery,
        _filter: PhysicsQueryFilter,
    ) -> Option<PhysicsRaycastHit> {
        None
    }

    fn overlap_aabb(
        &self,
        _query: PhysicsOverlapAABBQuery,
        _filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        Vec::new()
    }

    fn overlap_shape(
        &self,
        _query: PhysicsOverlapShapeQuery,
        _filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        Vec::new()
    }

    fn sweep_aabb(
        &self,
        _query: PhysicsSweepAABBQuery,
        _filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        None
    }

    fn sweep_shape(
        &self,
        _query: PhysicsSweepShapeQuery,
        _filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        None
    }

    fn detect_trigger_frame(&self, _max_event_count: usize) -> TriggerFrameResource {
        TriggerFrameResource::default()
    }

    fn reset(&mut self) {
        // Swift's recording double has an empty `reset()`: the captures persist so
        // the test can still assert on them after a tick.
    }
}

/// Swift `PhysicsSettingsResource(simulationMode: .play, backendKind:…,
/// fixedTimeStepSeconds: 1/60, maxSubstepsPerFrame: 1, …)`, keeping the remaining
/// memberwise defaults (`allowSleep: true`, `collisionSteps: 1`).
fn play_settings(
    backend_kind: PhysicsBackendKind,
    gravity: Float3,
    allow_sleep: bool,
) -> PhysicsSettingsResource {
    PhysicsSettingsResource::new(
        PhysicsSimulationMode::Play,
        backend_kind,
        gravity,
        1.0 / 60.0,
        1,
        allow_sleep,
        1,
        PhysicsCapacitySettings::default(),
    )
}

fn make_natsel_runtime() -> SceneRuntime {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(play_settings(
        PhysicsBackendKind::Natsel,
        Float3::ZERO,
        false,
    ));
    runtime
}

/// Swift `RigidBody(motionType:mass:linearVelocity:angularVelocity:gravityScale:
/// linearDamping:angularDamping:allowSleep:isSleeping:)` — only the fields these
/// tests vary; everything else keeps the `RigidBodyOptions` defaults.
fn rigid_body(
    motion_type: RigidBodyMotionType,
    mass: f32,
    linear_velocity: Float3,
    angular_velocity: Float3,
    gravity_scale: f32,
) -> RigidBodyOptions {
    RigidBodyOptions {
        motion_type,
        mass,
        linear_velocity,
        angular_velocity,
        gravity_scale,
        linear_damping: 0.0,
        angular_damping: 0.0,
        allow_sleep: false,
        is_sleeping: false,
        ..RigidBodyOptions::default()
    }
}

fn add_body(
    runtime: &mut SceneRuntime,
    position: Float3,
    motion_type: RigidBodyMotionType,
) -> EntityID {
    let entity = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::from_translation(position), entity);
    let mass = if motion_type == RigidBodyMotionType::Static {
        0.0
    } else {
        1.0
    };
    let _ = runtime.set_component(
        RigidBody::new(rigid_body(
            motion_type,
            mass,
            Float3::ZERO,
            Float3::ZERO,
            0.0,
        )),
        entity,
    );
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        entity,
    );
    entity
}

/// Swift `Constraint(...)` through `PhysicsJoint`'s compatibility initializer.
#[allow(clippy::too_many_arguments)]
fn constraint(
    kind: PhysicsJointKind,
    entity_a: EntityID,
    entity_b: EntityID,
    pivot_a: Float3,
    pivot_b: Float3,
    axis_a: Float3,
    axis_b: Float3,
    min_limit: f32,
    max_limit: f32,
) -> PhysicsJoint {
    PhysicsJoint::from_kind(
        kind,
        entity_a,
        entity_b,
        pivot_a,
        pivot_b,
        axis_a,
        axis_b,
        min_limit,
        max_limit,
        true,
        PhysicsJoint::DEFAULT_BREAK_LIMIT,
        PhysicsJoint::DEFAULT_BREAK_LIMIT,
    )
}

/// Swift `runtime.tick(deltaTime: 1.0 / 60.0)` — the frame index is irrelevant to
/// every phase that reads it in these tests.
fn tick_frame(runtime: &mut SceneRuntime) -> RuntimeScheduleReport {
    runtime.tick(1.0 / 60.0, 0, Vec::new())
}

fn world_translation_y(runtime: &SceneRuntime, entity: EntityID) -> f32 {
    runtime
        .world_transform(entity)
        .map(|transform| transform.translation().y)
        .unwrap_or(0.0)
}

fn world_translation_x(runtime: &SceneRuntime, entity: EntityID) -> f32 {
    runtime
        .world_transform(entity)
        .map(|transform| transform.translation().x)
        .unwrap_or(0.0)
}

fn linear_velocity(runtime: &SceneRuntime, entity: EntityID) -> Float3 {
    runtime
        .component::<RigidBody>(entity)
        .map(|body| body.linear_velocity)
        .unwrap_or(Float3::ZERO)
}

#[test]
fn configured_backend_kind_selects_natsel() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(play_settings(
        PhysicsBackendKind::Natsel,
        Float3::new(0.0, -9.81, 0.0),
        true,
    ));

    let entity = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, entity);
    let _ = runtime.set_component(RigidBody::default(), entity);
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::new(0.5, 0.5, 0.5),
            center: Float3::ZERO,
        }),
        entity,
    );

    let report = tick_frame(&mut runtime);

    assert_eq!(report.physics.backend_identifier, "natsel");
    assert_eq!(runtime.physics_frame_state().backend_identifier, "natsel");
    assert_eq!(report.physics.body_count, 1);
    assert_eq!(report.physics.constraint_count, 0);
}

#[test]
fn default_backend_kind_selects_preferred_when_simulation_runs() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(play_settings(
        PhysicsBackendKind::preferred(),
        Float3::ZERO,
        true,
    ));

    let entity = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, entity);
    let _ = runtime.set_component(RigidBody::default(), entity);
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::new(0.5, 0.5, 0.5),
            center: Float3::ZERO,
        }),
        entity,
    );

    let report = tick_frame(&mut runtime);

    assert_eq!(
        report.physics.backend_identifier,
        PhysicsBackendKind::preferred().raw_value()
    );
    assert_eq!(report.physics.body_count, 1);
}

#[test]
fn manual_backend_override_wins_over_configured_kind() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    let backend = SelectionRecordingPhysicsBackend::new();
    let captured = backend.capture_queue();
    runtime.set_physics_backend(Box::new(backend));
    runtime.set_physics_settings(play_settings(
        PhysicsBackendKind::Natsel,
        Float3::new(0.0, -9.81, 0.0),
        true,
    ));

    let entity = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, entity);
    let _ = runtime.set_component(RigidBody::default(), entity);
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        entity,
    );

    let report = tick_frame(&mut runtime);

    assert_eq!(report.physics.backend_identifier, "recording");
    assert_eq!(captured.lock().expect("prepare contexts").len(), 1);
}

#[test]
fn frame_state_reports_unsupported_features() {
    fn make_runtime(backend: Option<SelectionRecordingPhysicsBackend>) -> SceneRuntime {
        let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
        if let Some(backend) = backend {
            runtime.set_physics_backend(Box::new(backend));
        }
        runtime.set_physics_settings(play_settings(
            PhysicsBackendKind::Natsel,
            Float3::new(0.0, -9.81, 0.0),
            true,
        ));
        let entity = runtime.create_entity();
        let _ = runtime.set_local_transform(LocalTransform::IDENTITY, entity);
        let _ = runtime.set_component(RigidBody::default(), entity);
        let _ = runtime.set_component(
            Collider::with_shape(ColliderShape::Cylinder {
                radius: 0.5,
                half_height: 0.5,
                center: Float3::ZERO,
            }),
            entity,
        );
        runtime
    }

    let mut limited = SelectionRecordingPhysicsBackend::new();
    limited
        .capabilities
        .remove(PhysicsBackendCapabilities::CYLINDER_COLLIDERS);
    let mut limited_runtime = make_runtime(Some(limited));
    let _ = tick_frame(&mut limited_runtime);
    assert_eq!(
        limited_runtime.physics_frame_state().unsupported_features,
        PhysicsBackendCapabilities::CYLINDER_COLLIDERS
    );

    let mut natsel_runtime = make_runtime(None);
    let _ = tick_frame(&mut natsel_runtime);
    assert!(
        natsel_runtime
            .physics_frame_state()
            .unsupported_features
            .is_empty()
    );
}

#[test]
fn configured_natsel_backend_writes_back_stepped_body_state() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(play_settings(
        PhysicsBackendKind::Natsel,
        Float3::new(0.0, -9.81, 0.0),
        false,
    ));

    let entity = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, entity);
    let _ = runtime.set_component(
        RigidBody::new(rigid_body(
            RigidBodyMotionType::Dynamic,
            1.0,
            Float3::ZERO,
            Float3::ZERO,
            1.0,
        )),
        entity,
    );
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        entity,
    );

    let report = tick_frame(&mut runtime);
    let expected_velocity_y = (-9.81f64 / 60.0) as f32;
    let expected_position_y = expected_velocity_y / 60.0;

    assert_eq!(report.physics.backend_identifier, "natsel");
    assert_eq!(report.physics.writeback_count, 1);
    assert!((world_translation_y(&runtime, entity) - expected_position_y).abs() < 0.000_01);
    assert!((linear_velocity(&runtime, entity).y - expected_velocity_y).abs() < 0.000_01);
    assert_eq!(
        runtime
            .component::<RigidBody>(entity)
            .map(|body| body.is_sleeping),
        Some(false)
    );
}

#[test]
fn configured_natsel_backend_writes_back_stepped_body_rotation() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(play_settings(
        PhysicsBackendKind::Natsel,
        Float3::ZERO,
        false,
    ));

    let entity = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, entity);
    let _ = runtime.set_component(
        RigidBody::new(rigid_body(
            RigidBodyMotionType::Dynamic,
            1.0,
            Float3::ZERO,
            Float3::new(0.0, std::f32::consts::PI, 0.0),
            0.0,
        )),
        entity,
    );
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::new(0.5, 0.5, 0.5),
            center: Float3::ZERO,
        }),
        entity,
    );

    let report = tick_frame(&mut runtime);
    let expected_rotation =
        Quatf::from_angle_axis(std::f32::consts::PI / 60.0, Float3::new(0.0, 1.0, 0.0));
    let actual_rotation = Quatf::from_float4x4(
        runtime
            .world_transform(entity)
            .map(|transform| transform.matrix)
            .unwrap_or(MATRIX_IDENTITY_FLOAT4X4),
    );
    let alignment = simd_dot4(expected_rotation.vector, actual_rotation.vector).abs();

    assert_eq!(report.physics.backend_identifier, "natsel");
    assert_eq!(report.physics.writeback_count, 1);
    assert!(alignment > 0.999_99);
    assert_eq!(
        runtime
            .component::<RigidBody>(entity)
            .map(|body| body.angular_velocity),
        Some(Float3::new(0.0, std::f32::consts::PI, 0.0))
    );
}

#[test]
fn configured_natsel_backend_integrates_runtime_forces_and_impulses() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(play_settings(
        PhysicsBackendKind::Natsel,
        Float3::ZERO,
        false,
    ));

    let entity = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, entity);
    let _ = runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            is_sleeping: true,
            ..rigid_body(
                RigidBodyMotionType::Dynamic,
                2.0,
                Float3::ZERO,
                Float3::ZERO,
                0.0,
            )
        }),
        entity,
    );
    let mut collider = Collider::with_shape(ColliderShape::Sphere {
        radius: 0.5,
        center: Float3::ZERO,
    });
    collider.material = PhysicsMaterial::new(0.9, 0.25, 2.0);
    let _ = runtime.set_component(collider, entity);

    let applied_impulse = runtime.apply_linear_impulse(Float3::new(2.0, 0.0, 0.0), entity, true);
    let applied_angular_impulse =
        runtime.apply_angular_impulse(Float3::new(0.0, 0.0, 0.2), entity, true);
    let applied_force = runtime.apply_force(Float3::new(0.0, 120.0, 0.0), entity, true);
    let applied_torque = runtime.apply_torque(Float3::new(0.0, 0.0, 120.0), entity, true);
    assert!(applied_impulse);
    assert!(applied_angular_impulse);
    assert!(applied_force);
    assert!(applied_torque);

    let report = tick_frame(&mut runtime);
    let body = runtime.component::<RigidBody>(entity);

    // Real Natsel: sphere inertia I = (2/5)·m·r² = 0.4·2·0.25 = 0.2.
    // Linear impulse (2,0,0) on m=2  → Δv  = 1 in x
    // Force (0,120,0) for dt=1/60  → Δv  = 120/2 · 1/60 = 1 in y
    // Angular impulse (0,0,0.2)     → Δω = 0.2/0.2 = 1 in z
    // Torque (0,0,120) for dt=1/60 → Δω = 120/0.2 · 1/60 = 10 in z
    let expected_angular_z = 11.0f32;
    assert_eq!(report.physics.backend_identifier, "natsel");
    assert_eq!(report.physics.writeback_count, 1);
    assert!(
        (body
            .as_ref()
            .map(|body| body.linear_velocity.x)
            .unwrap_or(0.0)
            - 1.0)
            .abs()
            < 0.001
    );
    assert!(
        (body
            .as_ref()
            .map(|body| body.linear_velocity.y)
            .unwrap_or(0.0)
            - 1.0)
            .abs()
            < 0.001
    );
    assert!(
        (body
            .as_ref()
            .map(|body| body.angular_velocity.z)
            .unwrap_or(0.0)
            - expected_angular_z)
            .abs()
            < 0.01
    );
    assert_eq!(
        body.as_ref().map(|body| body.accumulated_force),
        Some(Float3::ZERO)
    );
    assert_eq!(
        body.as_ref().map(|body| body.accumulated_torque),
        Some(Float3::ZERO)
    );
    assert_eq!(
        body.as_ref().map(|body| body.accumulated_linear_impulse),
        Some(Float3::ZERO)
    );
    assert_eq!(
        body.as_ref().map(|body| body.accumulated_angular_impulse),
        Some(Float3::ZERO)
    );
    assert_eq!(body.as_ref().map(|body| body.is_sleeping), Some(false));
    // Symplectic Euler: position = newVelocity · dt
    assert!((world_translation_x(&runtime, entity) - (1.0f64 / 60.0) as f32).abs() < 0.001);
    assert!((world_translation_y(&runtime, entity) - (1.0f64 / 60.0) as f32).abs() < 0.001);
    assert_eq!(
        runtime
            .component::<Collider>(entity)
            .map(|collider| collider.material),
        Some(PhysicsMaterial::new(0.9, 0.25, 2.0))
    );
}

#[test]
fn configured_natsel_backend_exposes_contact_frame_events() {
    let mut runtime = make_natsel_runtime();
    let mover = add_body(&mut runtime, Float3::ZERO, RigidBodyMotionType::Dynamic);
    let wall = add_body(
        &mut runtime,
        Float3::new(0.75, 0.0, 0.0),
        RigidBodyMotionType::Static,
    );

    let first_report = tick_frame(&mut runtime);
    let first_frame = runtime.physics_contact_frame();
    let first_events: Vec<PhysicsContactEvent> = first_frame
        .began
        .iter()
        .chain(first_frame.stayed.iter())
        .copied()
        .collect();
    let first_pair = first_events
        .iter()
        .find(|event| {
            (event.entity_a == mover && event.entity_b == wall)
                || (event.entity_a == wall && event.entity_b == mover)
        })
        .copied();

    assert_eq!(first_report.physics.backend_identifier, "natsel");
    assert!(first_report.physics.contact_count >= 1);
    assert!(runtime.physics_frame_state().counts.contacts >= 1);
    assert!(first_pair.is_some());
    assert!(
        first_pair
            .map(|event| simd_length(event.normal) > 0.5)
            .unwrap_or(false)
    );

    let _ = runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(4.0, 0.0, 0.0)),
        mover,
    );
    let _ = tick_frame(&mut runtime);

    let ended_pair = runtime
        .physics_contact_frame()
        .ended
        .iter()
        .find(|event| {
            (event.entity_a == mover && event.entity_b == wall)
                || (event.entity_a == wall && event.entity_b == mover)
        })
        .copied();
    assert!(ended_pair.is_some());
}

#[test]
fn configured_natsel_backend_uses_ccd_for_fast_dynamic_bodies() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(PhysicsSettingsResource {
        collision_steps: 2,
        ..play_settings(PhysicsBackendKind::Natsel, Float3::ZERO, false)
    });

    let fast = runtime.create_entity();
    let _ = runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(-3.0, 0.0, 0.0)),
        fast,
    );
    let _ = runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            continuous_collision_detection: true,
            ..rigid_body(
                RigidBodyMotionType::Dynamic,
                1.0,
                Float3::new(360.0, 0.0, 0.0),
                Float3::ZERO,
                0.0,
            )
        }),
        fast,
    );
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.25,
            center: Float3::ZERO,
        }),
        fast,
    );

    let wall = add_body(&mut runtime, Float3::ZERO, RigidBodyMotionType::Static);
    let report = tick_frame(&mut runtime);
    let fast_x = runtime
        .world_transform(fast)
        .map(|transform| transform.translation().x)
        .unwrap_or(f32::MAX);
    let hit_pair = runtime
        .physics_contact_frame()
        .events()
        .into_iter()
        .find(|event| {
            (event.entity_a == fast && event.entity_b == wall)
                || (event.entity_a == wall && event.entity_b == fast)
        });

    assert_eq!(runtime.physics_settings().collision_steps, 2);
    assert!(report.physics.contact_count >= 1);
    assert!(hit_pair.is_some());
    assert!(
        fast_x < 0.25,
        "CCD body should not tunnel past the static collider (x={fast_x})"
    );
}

#[test]
fn configured_natsel_backend_applies_distance_constraint() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(play_settings(
        PhysicsBackendKind::Natsel,
        Float3::ZERO,
        false,
    ));

    let anchor = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, anchor);
    let _ = runtime.set_component(
        RigidBody::new(rigid_body(
            RigidBodyMotionType::Static,
            0.0,
            Float3::ZERO,
            Float3::ZERO,
            0.0,
        )),
        anchor,
    );
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        anchor,
    );

    let follower = runtime.create_entity();
    let _ = runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(6.0, 0.0, 0.0)),
        follower,
    );
    let _ = runtime.set_component(
        RigidBody::new(rigid_body(
            RigidBodyMotionType::Dynamic,
            1.0,
            Float3::ZERO,
            Float3::ZERO,
            0.0,
        )),
        follower,
    );
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        follower,
    );

    let constraint_entity = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, constraint_entity);
    let _ = runtime.set_component(
        constraint(
            PhysicsJointKind::Distance,
            anchor,
            follower,
            Float3::ZERO,
            Float3::ZERO,
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            0.0,
            2.0,
        ),
        constraint_entity,
    );

    // Real Natsel's iterative constraint solver converges over several frames
    // (vs. the fake impl's single-frame projection). Tick until convergence.
    let first_report = tick_frame(&mut runtime);
    assert_eq!(first_report.physics.backend_identifier, "natsel");
    assert_eq!(first_report.physics.constraint_count, 1);
    for _ in 0..240 {
        let _ = tick_frame(&mut runtime);
    }

    assert_eq!(
        runtime
            .world_transform(anchor)
            .map(|transform| transform.translation()),
        Some(Float3::ZERO)
    );
    let follower_x = world_translation_x(&runtime, follower);
    assert!(
        (follower_x - 2.0).abs() < 0.05,
        "distance constraint should pull follower to ~x=2 (got {follower_x})"
    );
}

#[test]
fn configured_natsel_backend_applies_point_to_point_constraint() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(play_settings(
        PhysicsBackendKind::Natsel,
        Float3::ZERO,
        false,
    ));

    let anchor = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, anchor);
    let _ = runtime.set_component(
        RigidBody::new(rigid_body(
            RigidBodyMotionType::Static,
            0.0,
            Float3::ZERO,
            Float3::ZERO,
            0.0,
        )),
        anchor,
    );
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        anchor,
    );

    let follower = runtime.create_entity();
    let _ = runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(5.0, 0.0, 0.0)),
        follower,
    );
    let _ = runtime.set_component(
        RigidBody::new(rigid_body(
            RigidBodyMotionType::Dynamic,
            1.0,
            Float3::ZERO,
            Float3::ZERO,
            0.0,
        )),
        follower,
    );
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        follower,
    );

    let constraint_entity = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, constraint_entity);
    let _ = runtime.set_component(
        constraint(
            PhysicsJointKind::PointToPoint,
            anchor,
            follower,
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(-1.0, 0.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            0.0,
            0.0,
        ),
        constraint_entity,
    );

    // Point-to-point pulls anchor.worldPivot → follower.worldPivot together.
    // anchor at 0 with pivotA=(1,0,0) → world pivot A = (1,0,0)
    // follower target: pos + pivotB = (1,0,0) ⇒ pos = (2,0,0)
    // Iterative solver — converge over several frames.
    let first_report = tick_frame(&mut runtime);
    assert_eq!(first_report.physics.backend_identifier, "natsel");
    assert_eq!(first_report.physics.constraint_count, 1);
    for _ in 0..240 {
        let _ = tick_frame(&mut runtime);
    }

    assert_eq!(
        runtime
            .world_transform(anchor)
            .map(|transform| transform.translation()),
        Some(Float3::ZERO)
    );
    let follower_x = world_translation_x(&runtime, follower);
    assert!(
        (follower_x - 2.0).abs() < 0.05,
        "point-to-point should pull follower to ~x=2 (got {follower_x})"
    );
}

#[test]
fn configured_natsel_backend_adds_velocity_layer_response_for_distance_constraint() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(play_settings(
        PhysicsBackendKind::Natsel,
        Float3::ZERO,
        false,
    ));

    let body_a = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, body_a);
    let _ = runtime.set_component(
        RigidBody::new(rigid_body(
            RigidBodyMotionType::Dynamic,
            1.0,
            Float3::new(1.0, 0.0, 0.0),
            Float3::ZERO,
            0.0,
        )),
        body_a,
    );
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        body_a,
    );

    let body_b = runtime.create_entity();
    let _ = runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(6.0, 0.0, 0.0)),
        body_b,
    );
    let _ = runtime.set_component(
        RigidBody::new(rigid_body(
            RigidBodyMotionType::Dynamic,
            1.0,
            Float3::new(5.0, 0.0, 0.0),
            Float3::ZERO,
            0.0,
        )),
        body_b,
    );
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        body_b,
    );

    let constraint_entity = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, constraint_entity);
    let _ = runtime.set_component(
        constraint(
            PhysicsJointKind::Distance,
            body_a,
            body_b,
            Float3::ZERO,
            Float3::ZERO,
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            0.0,
            2.0,
        ),
        constraint_entity,
    );

    // Two dynamic bodies separated by 6, maxDistance=2. Constraint must:
    //   - reduce separation to ~2 (position layer)
    //   - equalize velocities via momentum conservation (1·1 + 5·1)/(1+1) = 3
    // Iterative solver converges over many frames.
    let first_report = tick_frame(&mut runtime);
    assert_eq!(first_report.physics.backend_identifier, "natsel");
    assert_eq!(first_report.physics.constraint_count, 1);
    for _ in 0..240 {
        let _ = tick_frame(&mut runtime);
    }

    let position_a = world_translation_x(&runtime, body_a);
    let position_b = world_translation_x(&runtime, body_b);
    let velocity_a = linear_velocity(&runtime, body_a).x;
    let velocity_b = linear_velocity(&runtime, body_b).x;
    assert!(
        ((position_b - position_a) - 2.0).abs() < 0.1,
        "distance should converge to ~2 (got {})",
        position_b - position_a
    );
    assert!(
        (velocity_a - 3.0).abs() < 0.1,
        "bodyA velocity should converge to ~3 (got {velocity_a})"
    );
    assert!(
        (velocity_b - 3.0).abs() < 0.1,
        "bodyB velocity should converge to ~3 (got {velocity_b})"
    );
}

#[test]
fn configured_natsel_backend_applies_slider_constraint() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(play_settings(
        PhysicsBackendKind::Natsel,
        Float3::ZERO,
        false,
    ));

    let anchor = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, anchor);
    let _ = runtime.set_component(
        RigidBody::new(rigid_body(
            RigidBodyMotionType::Static,
            0.0,
            Float3::ZERO,
            Float3::ZERO,
            0.0,
        )),
        anchor,
    );
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        anchor,
    );

    let follower = runtime.create_entity();
    let _ = runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(2.0, 2.0, 0.0)),
        follower,
    );
    let _ = runtime.set_component(
        RigidBody::new(rigid_body(
            RigidBodyMotionType::Dynamic,
            1.0,
            Float3::new(1.0, -3.0, 0.0),
            Float3::ZERO,
            0.0,
        )),
        follower,
    );
    let _ = runtime.set_component(
        Collider::with_shape(ColliderShape::Sphere {
            radius: 0.5,
            center: Float3::ZERO,
        }),
        follower,
    );

    let constraint_entity = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, constraint_entity);
    let _ = runtime.set_component(
        constraint(
            PhysicsJointKind::Slider,
            anchor,
            follower,
            Float3::ZERO,
            Float3::ZERO,
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            1.0,
            3.0,
        ),
        constraint_entity,
    );

    // Slider locks motion to the x-axis (axisA = axisB = (1,0,0)).
    // After a few frames the perpendicular y velocity is killed and y
    // settles back near 0; x continues unconstrained until limits engage.
    let first_report = tick_frame(&mut runtime);
    assert_eq!(first_report.physics.backend_identifier, "natsel");
    assert_eq!(first_report.physics.constraint_count, 1);
    for _ in 0..60 {
        let _ = tick_frame(&mut runtime);
    }

    let follower_y = world_translation_y(&runtime, follower);
    let velocity_y = linear_velocity(&runtime, follower).y;
    assert!(
        follower_y.abs() < 0.1,
        "slider should pull y to ~0 (got {follower_y})"
    );
    assert!(
        velocity_y.abs() < 0.1,
        "slider should kill y velocity (got {velocity_y})"
    );
}

#[test]
fn configured_natsel_backend_creates_hinge_constraint() {
    let mut runtime = make_natsel_runtime();
    let anchor = add_body(&mut runtime, Float3::ZERO, RigidBodyMotionType::Static);
    let follower = add_body(
        &mut runtime,
        Float3::new(2.0, 0.0, 0.0),
        RigidBodyMotionType::Dynamic,
    );

    let constraint_entity = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, constraint_entity);
    let _ = runtime.set_component(
        constraint(
            PhysicsJointKind::Hinge,
            anchor,
            follower,
            Float3::ZERO,
            Float3::ZERO,
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            -std::f32::consts::PI,
            std::f32::consts::PI,
        ),
        constraint_entity,
    );

    let report = tick_frame(&mut runtime);
    assert_eq!(report.physics.backend_identifier, "natsel");
    assert_eq!(report.physics.constraint_count, 1);
}

#[test]
fn configured_natsel_backend_applies_fixed_constraint() {
    let mut runtime = make_natsel_runtime();
    let anchor = add_body(&mut runtime, Float3::ZERO, RigidBodyMotionType::Static);
    let follower = add_body(
        &mut runtime,
        Float3::new(3.0, 0.0, 0.0),
        RigidBodyMotionType::Dynamic,
    );

    let constraint_entity = runtime.create_entity();
    let _ = runtime.set_local_transform(LocalTransform::IDENTITY, constraint_entity);
    let _ = runtime.set_component(
        constraint(
            PhysicsJointKind::Fixed,
            anchor,
            follower,
            Float3::ZERO,
            Float3::ZERO,
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            0.0,
            0.0,
        ),
        constraint_entity,
    );

    let first_report = tick_frame(&mut runtime);
    assert_eq!(first_report.physics.backend_identifier, "natsel");
    assert_eq!(first_report.physics.constraint_count, 1);
    for _ in 0..240 {
        let _ = tick_frame(&mut runtime);
    }

    let follower_x = world_translation_x(&runtime, follower);
    assert!(
        follower_x.abs() < 0.25,
        "fixed constraint should weld follower near anchor (got {follower_x})"
    );
}
