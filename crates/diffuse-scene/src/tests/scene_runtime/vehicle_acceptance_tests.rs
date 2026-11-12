//! Ported from `Engine/Tests/SceneRuntimeTests/VehicleAcceptanceTests.swift`.
//!
//! End-to-end driving checks: material friction, a ramp jump, reversing out of
//! a chassis collision, and inheriting a kinematic platform's motion.

use diffuse_math::simd::simd_compat::{Float3, Quatf};

use crate::components::core::registry::ComponentRegistry;
use crate::entity_id::EntityID;
use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;
use crate::physics::collider::{Collider, ColliderShape};
use crate::physics::physics_settings::{PhysicsCapacitySettings, PhysicsSettingsResource};
use crate::physics::physics_types::PhysicsSimulationMode;
use crate::physics::rigid_body::{
    PhysicsKinematicTarget, RigidBody, RigidBodyMotionType, RigidBodyOptions,
};
use crate::physics::vehicles::vehicle::Vehicle;
use crate::physics::vehicles::vehicle_powertrain::VehicleEngineConfiguration;
use crate::physics::vehicles::vehicle_state::VehicleCommand;
use crate::runtime_world::LocalTransform;
use crate::scene_runtime::SceneRuntime;

const DELTA_TIME: f64 = 1.0 / 60.0;

fn runtime() -> SceneRuntime {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        backend_kind: PhysicsBackendKind::preferred(),
        fixed_time_step_seconds: DELTA_TIME,
        max_substeps_per_frame: 1,
        allow_sleep: false,
        capacity: PhysicsCapacitySettings::new(PhysicsCapacitySettings::default().max_bodies, 1),
        ..PhysicsSettingsResource::default()
    });
    runtime
}

fn add_static_box(
    runtime: &mut SceneRuntime,
    position: Float3,
    half_extents: Float3,
    friction: f32,
    rotation: Option<Quatf>,
) -> EntityID {
    let entity = runtime.create_entity();
    let mut transform = LocalTransform::from_translation(position);
    if let Some(rotation) = rotation {
        transform = transform.with_rotation(rotation);
    }
    runtime.set_local_transform(transform, entity);
    let mut collider = Collider::with_shape(ColliderShape::Box {
        half_extents,
        center: Float3::ZERO,
    });
    collider.material.friction = friction;
    collider.material.restitution = 0.0;
    runtime.set_component(collider, entity);
    entity
}

fn add_car(runtime: &mut SceneRuntime, position: Float3, max_torque: f32) -> EntityID {
    let entity = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::from_translation(position), entity);
    let mut collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::new(0.8, 0.2, 1.5),
        center: Float3::ZERO,
    });
    collider.material.friction = 0.8;
    collider.material.restitution = 0.0;
    runtime.set_component(collider, entity);
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            mass: 1_200.0,
            linear_damping: 0.02,
            angular_damping: 0.05,
            allow_sleep: false,
            center_of_mass_override: Some(Float3::new(0.0, -0.3, 0.0)),
            ..RigidBodyOptions::default()
        }),
        entity,
    );
    let mut vehicle = Vehicle::wheeled();
    vehicle.engine = VehicleEngineConfiguration::new(max_torque, 1_000.0, 6_000.0, 0.5, 0.2);
    runtime.set_component(vehicle, entity);
    entity
}

fn drive(
    runtime: &mut SceneRuntime,
    vehicle: EntityID,
    command: VehicleCommand,
    frames: std::ops::Range<u64>,
) {
    for frame in frames {
        runtime.submit_vehicle_command(command, vehicle);
        let report = runtime.tick(DELTA_TIME, frame, Vec::new());
        assert!(report.physics.error.is_none());
    }
}

fn tick(runtime: &mut SceneRuntime, frame: u64) {
    let report = runtime.tick(DELTA_TIME, frame, Vec::new());
    assert!(report.physics.error.is_none());
}

fn translation(runtime: &SceneRuntime, entity: EntityID) -> Float3 {
    runtime
        .world_transform(entity)
        .map(|transform| transform.translation())
        .unwrap_or(Float3::ZERO)
}

fn has_wheel_contact(runtime: &SceneRuntime, vehicle: EntityID) -> bool {
    runtime
        .vehicle_state_frame()
        .states
        .get(&vehicle)
        .is_some_and(|state| state.wheels.iter().any(|wheel| wheel.has_contact))
}

/// Terrain friction changes longitudinal acceleration.
#[test]
fn friction_materials() {
    fn travel_distance(friction: f32) -> f32 {
        let mut runtime = runtime();
        add_static_box(
            &mut runtime,
            Float3::new(0.0, -0.5, 0.0),
            Float3::new(50.0, 0.5, 50.0),
            friction,
            None,
        );
        let car = add_car(&mut runtime, Float3::new(0.0, 1.0, 0.0), 900.0);
        drive(&mut runtime, car, VehicleCommand::default(), 0..90);
        let before = translation(&runtime, car).z;
        drive(
            &mut runtime,
            car,
            VehicleCommand {
                throttle: 1.0,
                ..VehicleCommand::default()
            },
            90..270,
        );
        translation(&runtime, car).z - before
    }

    let high_friction_distance = travel_distance(1.0);
    let low_friction_distance = travel_distance(0.05);
    assert!(high_friction_distance > low_friction_distance + 0.25);
}

/// The vehicle climbs a ramp and becomes airborne after the lip.
#[test]
fn ramp_and_jump() {
    let mut runtime = runtime();
    add_static_box(
        &mut runtime,
        Float3::new(0.0, -0.5, -5.0),
        Float3::new(5.0, 0.5, 7.0),
        1.0,
        None,
    );
    add_static_box(
        &mut runtime,
        Float3::new(0.0, 0.3, 4.5),
        Float3::new(3.0, 0.25, 3.0),
        1.0,
        Some(Quatf::from_angle_axis(
            -std::f32::consts::PI / 12.0,
            Float3::new(1.0, 0.0, 0.0),
        )),
    );
    let car = add_car(&mut runtime, Float3::new(0.0, 1.0, -3.0), 1_500.0);

    let mut had_ground_contact = false;
    let mut became_airborne = false;
    let mut max_height = f32::NEG_INFINITY;
    for frame in 0..600u64 {
        runtime.submit_vehicle_command(
            VehicleCommand {
                throttle: if frame < 90 { 0.0 } else { 1.0 },
                ..VehicleCommand::default()
            },
            car,
        );
        tick(&mut runtime, frame);
        let has_contact = has_wheel_contact(&runtime, car);
        had_ground_contact = had_ground_contact || has_contact;
        became_airborne = became_airborne || (had_ground_contact && !has_contact && frame > 180);
        max_height = max_height.max(translation(&runtime, car).y);
    }

    assert!(max_height > 1.4);
    assert!(became_airborne);
}

/// The vehicle can reverse away after a chassis collision.
#[test]
fn collision_recovery() {
    let mut runtime = runtime();
    add_static_box(
        &mut runtime,
        Float3::new(0.0, -0.5, 0.0),
        Float3::new(30.0, 0.5, 30.0),
        1.0,
        None,
    );
    let wall = add_static_box(
        &mut runtime,
        Float3::new(0.0, 1.0, 6.0),
        Float3::new(3.0, 1.0, 0.5),
        1.0,
        None,
    );
    let car = add_car(&mut runtime, Float3::new(0.0, 1.0, 0.0), 1_500.0);
    drive(&mut runtime, car, VehicleCommand::default(), 0..90);

    let mut hit_wall = false;
    for frame in 90..420u64 {
        runtime.submit_vehicle_command(
            VehicleCommand {
                throttle: 1.0,
                ..VehicleCommand::default()
            },
            car,
        );
        tick(&mut runtime, frame);
        hit_wall = hit_wall
            || runtime.physics_event_frame().contacts.iter().any(|event| {
                (event.entity_a == car && event.entity_b == wall)
                    || (event.entity_a == wall && event.entity_b == car)
            });
    }
    let collision_position = translation(&runtime, car).z;
    drive(
        &mut runtime,
        car,
        VehicleCommand {
            throttle: -1.0,
            ..VehicleCommand::default()
        },
        420..720,
    );
    let recovered_position = translation(&runtime, car).z;

    assert!(hit_wall);
    assert!(collision_position < 6.0);
    assert!(recovered_position < collision_position - 0.5);
}

/// Wheel contacts inherit a kinematic moving platform.
#[test]
fn moving_platform() {
    let mut runtime = runtime();
    let platform = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, -0.25, 0.0)),
        platform,
    );
    let mut collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::new(4.0, 0.25, 4.0),
        center: Float3::ZERO,
    });
    collider.material.friction = 1.0;
    collider.material.restitution = 0.0;
    runtime.set_component(collider, platform);
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            motion_type: RigidBodyMotionType::Kinematic,
            ..RigidBodyOptions::default()
        }),
        platform,
    );
    let car = add_car(&mut runtime, Float3::new(0.0, 1.0, 0.0), 900.0);
    drive(&mut runtime, car, VehicleCommand::default(), 0..120);
    assert!(
        runtime
            .vehicle_state_frame()
            .states
            .get(&car)
            .is_some_and(|state| state
                .wheels
                .iter()
                .any(|wheel| wheel.contact_entity == Some(platform)))
    );

    let before = translation(&runtime, car).x;
    for frame in 120..300u64 {
        let target_x = (frame - 119) as f32 * 0.01;
        runtime.update_component::<RigidBody>(platform, |body| {
            body.kinematic_target = Some(PhysicsKinematicTarget::new(Float3::new(
                target_x, -0.25, 0.0,
            )));
        });
        runtime.submit_vehicle_command(VehicleCommand::default(), car);
        tick(&mut runtime, frame);
    }
    let after = translation(&runtime, car).x;

    assert!(after > before + 0.3);
    assert!(
        runtime
            .vehicle_state_frame()
            .states
            .get(&car)
            .is_some_and(|state| state
                .wheels
                .iter()
                .any(|wheel| wheel.contact_entity == Some(platform)))
    );
}
