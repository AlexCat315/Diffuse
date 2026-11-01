//! Ported from `Engine/Tests/SceneRuntimeTests/PhysicsJointTests.swift`.
//!
//! Swift's `tick(deltaTime:)` has no frame index, so every call here supplies one
//! and no input events. `@Test(arguments:)` over the two typed configurations
//! becomes two tests sharing the `creates_typed_joints` helper.

use diffuse_math::simd::simd_compat::Float3;

use crate::components::core::registry::ComponentRegistry;
use crate::entity_id::EntityID;
use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;
use crate::physics::collider::{Collider, ColliderShape};
use crate::physics::joints::physics_joint::PhysicsJoint;
use crate::physics::joints::physics_joint_configuration::{
    ConeJointConfiguration, DistanceJointConfiguration, PhysicsJointConfiguration,
    PhysicsJointMotor, PhysicsJointMotorMode, PhysicsJointSpring, SixDofJointConfiguration,
};
use crate::physics::physics_events::PhysicsJointBreakEvent;
use crate::physics::physics_settings::{PhysicsCapacitySettings, PhysicsSettingsResource};
use crate::physics::physics_types::PhysicsSimulationMode;
use crate::physics::rigid_body::{RigidBody, RigidBodyMotionType, RigidBodyOptions};
use crate::runtime_world::LocalTransform;
use crate::scene_runtime::SceneRuntime;

const DELTA_TIME: f64 = 1.0 / 60.0;

fn runtime() -> SceneRuntime {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        backend_kind: PhysicsBackendKind::Natsel,
        gravity: Float3::ZERO,
        fixed_time_step_seconds: DELTA_TIME,
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

/// Swift `PhysicsJoint(configuration:entityA:entityB:)`: zero pivots, enabled and the
/// maximum finite break limits.
fn joint_at(
    configuration: PhysicsJointConfiguration,
    entity_a: EntityID,
    entity_b: EntityID,
) -> PhysicsJoint {
    PhysicsJoint::new(
        configuration,
        entity_a,
        entity_b,
        Float3::ZERO,
        Float3::ZERO,
        true,
        PhysicsJoint::DEFAULT_BREAK_LIMIT,
        PhysicsJoint::DEFAULT_BREAK_LIMIT,
    )
}

/// A joint is resent when a connected body must be recreated.
#[test]
fn joint_survives_connected_body_recreation() {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        backend_kind: PhysicsBackendKind::Natsel,
        gravity: Float3::ZERO,
        fixed_time_step_seconds: DELTA_TIME,
        max_substeps_per_frame: 1,
        allow_sleep: false,
        capacity: PhysicsCapacitySettings::new(65_536, 1),
        ..PhysicsSettingsResource::default()
    });

    let first = runtime.create_entity();
    let second = runtime.create_entity();
    for (entity, x) in [(first, 0.0_f32), (second, 1.0_f32)] {
        runtime.set_local_transform(
            LocalTransform::from_translation(Float3::new(x, 0.0, 0.0)),
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
        runtime.set_component(Collider::with_shape(sphere(0.4)), entity);
    }
    let joint = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, joint);
    runtime.set_component(
        joint_at(PhysicsJointConfiguration::Point, first, second),
        joint,
    );

    let _ = runtime.tick(DELTA_TIME, 0, Vec::new());
    assert_eq!(runtime.physics_frame_state().synchronization.constraints, 1);

    runtime.update_component::<Collider>(first, |collider| {
        collider.set_shape(sphere(0.6));
    });
    let recreated = runtime.tick(DELTA_TIME, 1, Vec::new());
    assert!(recreated.physics.error.is_none());
    assert_eq!(runtime.physics_frame_state().synchronization.bodies, 1);
    assert_eq!(runtime.physics_frame_state().synchronization.constraints, 1);

    let _ = runtime.tick(DELTA_TIME, 2, Vec::new());
    assert_eq!(runtime.physics_frame_state().synchronization.bodies, 0);
    assert_eq!(runtime.physics_frame_state().synchronization.constraints, 0);
}

/// Joint break thresholds emit events and disable the authored joint.
#[test]
fn break_event() {
    let mut runtime = runtime();

    let anchor = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, anchor);
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            motion_type: RigidBodyMotionType::Static,
            ..RigidBodyOptions::default()
        }),
        anchor,
    );
    runtime.set_component(Collider::with_shape(sphere(0.25)), anchor);

    let body = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 3.0, 0.0)),
        body,
    );
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            motion_type: RigidBodyMotionType::Dynamic,
            mass: 1.0,
            gravity_scale: 0.0,
            allow_sleep: false,
            ..RigidBodyOptions::default()
        }),
        body,
    );
    runtime.set_component(Collider::with_shape(sphere(0.25)), body);

    let joint_entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, joint_entity);
    runtime.set_component(
        PhysicsJoint::new(
            PhysicsJointConfiguration::Distance(DistanceJointConfiguration::new(
                0.0,
                0.5,
                PhysicsJointSpring::default(),
            )),
            anchor,
            body,
            Float3::ZERO,
            Float3::ZERO,
            true,
            0.001,
            PhysicsJoint::DEFAULT_BREAK_LIMIT,
        ),
        joint_entity,
    );

    let mut event: Option<PhysicsJointBreakEvent> = None;
    for frame in 0..30 {
        if event.is_some() {
            break;
        }
        let _ = runtime.tick(DELTA_TIME, frame, Vec::new());
        event = runtime.physics_event_frame().joint_breaks.first().copied();
    }

    let recorded = event.expect("joint break event");
    assert_eq!(recorded.joint_entity, joint_entity);
    assert!(recorded.force > 0.001);
    assert_eq!(
        runtime
            .component::<PhysicsJoint>(joint_entity)
            .map(|joint| joint.is_enabled),
        Some(false)
    );
}

/// The shared body of Swift's `createsTypedJoints(configuration:)`.
fn creates_typed_joints(configuration: PhysicsJointConfiguration) {
    let mut runtime = runtime();

    let anchor = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, anchor);
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            motion_type: RigidBodyMotionType::Static,
            ..RigidBodyOptions::default()
        }),
        anchor,
    );
    runtime.set_component(Collider::with_shape(sphere(0.25)), anchor);

    let body = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 1.0, 0.0)),
        body,
    );
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            motion_type: RigidBodyMotionType::Dynamic,
            mass: 1.0,
            gravity_scale: 0.0,
            allow_sleep: false,
            ..RigidBodyOptions::default()
        }),
        body,
    );
    runtime.set_component(Collider::with_shape(sphere(0.25)), body);

    let joint_entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::IDENTITY, joint_entity);
    runtime.set_component(joint_at(configuration, anchor, body), joint_entity);

    let report = runtime.tick(DELTA_TIME, 0, Vec::new());
    assert!(report.physics.error.is_none());
    assert_eq!(report.physics.constraint_count, 1);
    assert_eq!(runtime.physics_frame_state().counts.constraints, 1);
}

/// Natsel creates a cone joint from a typed configuration.
#[test]
fn creates_cone_joint() {
    creates_typed_joints(PhysicsJointConfiguration::Cone(
        ConeJointConfiguration::new(
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            0.4,
            -0.2,
            0.2,
            PhysicsJointSpring::new(2.0, 0.5),
        ),
    ));
}

/// Natsel creates a six-DOF joint from a typed configuration.
#[test]
fn creates_six_dof_joint() {
    creates_typed_joints(PhysicsJointConfiguration::SixDof(
        SixDofJointConfiguration::new(
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(-0.25, 0.0, 0.0),
            Float3::new(0.25, 0.0, 0.0),
            Float3::new(-0.1, -0.2, -0.3),
            Float3::new(0.1, 0.2, 0.3),
            PhysicsJointMotor::new(PhysicsJointMotorMode::Position, 0.0, 0.0, 10.0),
            PhysicsJointMotor::new(PhysicsJointMotorMode::Velocity, 0.0, 0.1, 10.0),
            PhysicsJointSpring::default(),
        ),
    ));
}
