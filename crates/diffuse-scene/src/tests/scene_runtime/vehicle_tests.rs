//! Ported from `Engine/Tests/SceneRuntimeTests/VehicleTests.swift`.
//!
//! Swift's `tick(deltaTime:)` has no frame index; the Rust schedule takes one plus
//! the frame's input events, so every call here supplies the loop index and no
//! input.

use diffuse_math::simd::simd_compat::Float3;

use crate::components::core::registry::ComponentRegistry;
use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;
use crate::physics::collider::{Collider, ColliderShape};
use crate::physics::physics_settings::{PhysicsCapacitySettings, PhysicsSettingsResource};
use crate::physics::physics_types::{PhysicsBackendErrorCode, PhysicsSimulationMode};
use crate::physics::rigid_body::{RigidBody, RigidBodyOptions};
use crate::physics::vehicles::vehicle::Vehicle;
use crate::physics::vehicles::vehicle_controller_configuration::{
    VehicleControllerConfiguration, VehicleTrackConfiguration,
};
use crate::physics::vehicles::vehicle_powertrain::{
    VehicleEngineConfiguration, VehicleTransmissionConfiguration,
};
use crate::physics::vehicles::vehicle_state::{VehicleCommand, VehicleState};
use crate::physics::vehicles::vehicle_wheel_configuration::VehicleTransmissionMode;
use crate::runtime_world::LocalTransform;
use crate::scene_runtime::SceneRuntime;
use crate::serialization::scene_serializer::SceneSerializer;

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

fn make_runtime() -> (SceneRuntime, crate::entity_id::EntityID) {
    let mut runtime = runtime();

    let ground = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, -0.5, 0.0)),
        ground,
    );
    let mut collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::new(50.0, 0.5, 50.0),
        center: Float3::ZERO,
    });
    collider.material.friction = 1.0;
    collider.material.restitution = 0.0;
    runtime.set_component(collider, ground);

    let vehicle = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 1.0, 0.0)),
        vehicle,
    );
    let mut collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::new(0.8, 0.2, 1.5),
        center: Float3::ZERO,
    });
    collider.material.friction = 0.8;
    collider.material.restitution = 0.0;
    runtime.set_component(collider, vehicle);
    runtime.set_component(car_body(), vehicle);
    runtime.set_component(Vehicle::wheeled(), vehicle);
    (runtime, vehicle)
}

fn car_body() -> RigidBody {
    RigidBody::new(RigidBodyOptions {
        mass: 1_200.0,
        linear_damping: 0.02,
        angular_damping: 0.05,
        allow_sleep: false,
        center_of_mass_override: Some(Float3::new(0.0, -0.3, 0.0)),
        ..RigidBodyOptions::default()
    })
}

fn tick(runtime: &mut SceneRuntime, frame: u64) {
    let report = runtime.tick(DELTA_TIME, frame, Vec::new());
    assert!(report.physics.error.is_none());
}

fn state(runtime: &SceneRuntime, vehicle: crate::entity_id::EntityID) -> Option<VehicleState> {
    runtime.vehicle_state_frame().states.get(&vehicle).cloned()
}

fn z(runtime: &SceneRuntime, vehicle: crate::entity_id::EntityID) -> f32 {
    runtime
        .world_transform(vehicle)
        .map(|transform| transform.translation().z)
        .unwrap_or(0.0)
}

/// Drive the wheeled vehicle, check wheel contact and that current-frame
/// throttle moves it.
#[test]
fn drives_and_reports_wheel_state() {
    let (mut runtime, vehicle) = make_runtime();
    for frame in 0..90u64 {
        runtime.submit_vehicle_command(VehicleCommand::default(), vehicle);
        tick(&mut runtime, frame);
    }

    let settled = state(&runtime, vehicle).expect("vehicle state");
    assert_eq!(settled.wheels.len(), 4);
    assert!(settled.wheels.iter().any(|wheel| wheel.has_contact));
    let before = z(&runtime, vehicle);

    for frame in 90..270u64 {
        runtime.submit_vehicle_command(
            VehicleCommand {
                throttle: 1.0,
                ..VehicleCommand::default()
            },
            vehicle,
        );
        tick(&mut runtime, frame);
    }

    let after = z(&runtime, vehicle);
    let drove = state(&runtime, vehicle).expect("vehicle state");
    assert!(after > before + 1.0);
    assert!(drove.engine_rpm > 1_000.0);
    assert!(drove.forward_speed > 0.0);
    assert_eq!(drove.wheels.len(), 4);
}

/// The tracked controller drives six wheels and pivots through the shared
/// command API.
#[test]
fn tracked_vehicle_drives_and_pivots() {
    let (mut runtime, vehicle) = make_runtime();
    runtime.set_component(Vehicle::tracked_default(), vehicle);

    for frame in 0..120u64 {
        runtime.submit_vehicle_command(VehicleCommand::default(), vehicle);
        tick(&mut runtime, frame);
    }
    assert!(
        state(&runtime, vehicle)
            .expect("vehicle state")
            .wheels
            .iter()
            .any(|wheel| wheel.has_contact)
    );
    let before = z(&runtime, vehicle);
    for frame in 120..300u64 {
        runtime.submit_vehicle_command(
            VehicleCommand {
                throttle: 1.0,
                ..VehicleCommand::default()
            },
            vehicle,
        );
        tick(&mut runtime, frame);
    }
    let after = z(&runtime, vehicle);
    let driven = state(&runtime, vehicle).expect("vehicle state");
    assert!(after > before + 1.0);
    assert_eq!(driven.wheels.len(), 6);
    assert!(driven.wheels.iter().any(|wheel| wheel.has_contact));

    let rotation_before = runtime
        .world_transform(vehicle)
        .map(|transform| transform.matrix);
    for frame in 300..390u64 {
        runtime.submit_vehicle_command(
            VehicleCommand {
                steering: 1.0,
                ..VehicleCommand::default()
            },
            vehicle,
        );
        tick(&mut runtime, frame);
    }
    let rotation_after = runtime
        .world_transform(vehicle)
        .map(|transform| transform.matrix);
    assert_ne!(rotation_before, rotation_after);
}

/// The motorcycle controller balances and drives two wheels through the shared
/// state frame.
#[test]
fn motorcycle_drives() {
    let (mut runtime, vehicle) = make_runtime();
    let mut collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::new(0.2, 0.3, 0.4),
        center: Float3::ZERO,
    });
    collider.material.friction = 0.8;
    collider.material.restitution = 0.0;
    runtime.set_component(collider, vehicle);
    runtime.set_component(
        RigidBody::new(RigidBodyOptions {
            mass: 240.0,
            linear_damping: 0.02,
            angular_damping: 0.05,
            allow_sleep: false,
            center_of_mass_override: Some(Float3::new(0.0, -0.3, 0.0)),
            ..RigidBodyOptions::default()
        }),
        vehicle,
    );
    runtime.set_component(Vehicle::motorcycle_default(), vehicle);

    for frame in 0..120u64 {
        runtime.submit_vehicle_command(VehicleCommand::default(), vehicle);
        tick(&mut runtime, frame);
    }
    let before = z(&runtime, vehicle);
    for frame in 120..300u64 {
        runtime.submit_vehicle_command(
            VehicleCommand {
                throttle: 1.0,
                steering: 0.1,
                ..VehicleCommand::default()
            },
            vehicle,
        );
        tick(&mut runtime, frame);
    }
    let after = z(&runtime, vehicle);
    let drove = state(&runtime, vehicle).expect("vehicle state");
    assert!(after > before + 0.5);
    assert_eq!(drove.wheels.len(), 2);
    assert!(drove.wheels.iter().any(|wheel| wheel.has_contact));
    assert!(drove.engine_rpm > 1_000.0);
}

/// Changing the engine rebuilds incrementally; removing the component clears
/// the frame state.
#[test]
fn incremental_rebuild_and_removal() {
    let (mut runtime, vehicle) = make_runtime();
    tick(&mut runtime, 0);
    assert_eq!(
        state(&runtime, vehicle)
            .expect("vehicle state")
            .wheels
            .len(),
        4
    );

    runtime.update_component::<Vehicle>(vehicle, |vehicle| {
        vehicle.engine.max_torque = 900.0;
    });
    tick(&mut runtime, 1);
    assert_eq!(
        state(&runtime, vehicle)
            .expect("vehicle state")
            .wheels
            .len(),
        4
    );

    runtime.remove_component::<Vehicle>(vehicle);
    tick(&mut runtime, 2);
    assert!(state(&runtime, vehicle).is_none());
}

/// Recorded vehicle commands replay to identical wheel-state hashes.
#[test]
fn command_recording_replay() {
    let (mut recording, vehicle) = make_runtime();
    recording.begin_physics_command_recording(120);
    for frame in 0..90u64 {
        let command = if frame < 30 {
            VehicleCommand::default()
        } else {
            VehicleCommand {
                throttle: 0.8,
                steering: if frame < 60 { 0.15 } else { -0.1 },
                ..VehicleCommand::default()
            }
        };
        recording.submit_vehicle_command(command, vehicle);
        recording.tick(DELTA_TIME, frame, Vec::new());
    }
    let tape = recording.end_physics_command_recording();
    let expected_state = state(&recording, vehicle);
    assert_eq!(tape.frames.len(), 90);
    assert!(
        tape.frames
            .iter()
            .any(|frame| !frame.vehicle_commands.is_empty())
    );

    let (mut replay_runtime, replay_vehicle) = make_runtime();
    let replay = replay_runtime.replay_physics_commands(&tape);
    assert!(replay.is_deterministic());
    assert_eq!(replay.replayed_frame_count, 90);
    assert_eq!(state(&replay_runtime, replay_vehicle), expected_state);
}

/// An empty wheel set is surfaced as a native argument error.
#[test]
fn invalid_configuration_reports_error() {
    let (mut runtime, vehicle) = make_runtime();
    runtime.set_component(
        Vehicle::new(
            VehicleControllerConfiguration::Wheeled,
            Vec::new(),
            Vec::new(),
            Vec::new(),
            VehicleEngineConfiguration::default(),
            VehicleTransmissionConfiguration::default(),
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 0.0, 1.0),
            std::f32::consts::PI,
            true,
        ),
        vehicle,
    );
    let report = runtime.tick(DELTA_TIME, 0, Vec::new());
    assert_eq!(
        report.physics.error.map(|error| error.code),
        Some(PhysicsBackendErrorCode::InvalidArgument)
    );
}

/// A track that does not contain its driven wheel is rejected.
#[test]
fn invalid_tracked_configuration_reports_error() {
    let (mut runtime, vehicle) = make_runtime();
    let mut tracked = Vehicle::tracked_default();
    let VehicleControllerConfiguration::Tracked(mut configuration) = tracked.controller else {
        panic!("Vehicle::tracked_default() returned the wrong controller");
    };
    configuration.left_track = VehicleTrackConfiguration::new(2, vec![0, 1]);
    tracked.controller = VehicleControllerConfiguration::Tracked(configuration);
    runtime.set_component(tracked, vehicle);

    let report = runtime.tick(DELTA_TIME, 0, Vec::new());
    assert_eq!(
        report.physics.error.map(|error| error.code),
        Some(PhysicsBackendErrorCode::InvalidArgument)
    );
}

/// Manual gear commands are checked against the configured transmission.
#[test]
fn invalid_manual_gear_reports_error() {
    let (mut runtime, vehicle) = make_runtime();
    runtime.update_component::<Vehicle>(vehicle, |vehicle| {
        vehicle.transmission = VehicleTransmissionConfiguration::new(
            VehicleTransmissionMode::Manual,
            vec![2.5, 1.5],
            vec![-2.8],
            0.5,
            0.3,
            0.5,
            4_000.0,
            2_000.0,
            10.0,
        );
    });
    runtime.submit_vehicle_command(
        VehicleCommand {
            throttle: 1.0,
            manual_gear: Some(3),
            ..VehicleCommand::default()
        },
        vehicle,
    );

    let report = runtime.tick(DELTA_TIME, 0, Vec::new());
    assert_eq!(
        report.physics.error.map(|error| error.code),
        Some(PhysicsBackendErrorCode::InvalidArgument)
    );
}

/// The authored configuration survives a scene round-trip.
#[test]
fn scene_round_trip() {
    let mut original = SceneRuntime::new(ComponentRegistry::built_in());
    let entity = original.create_entity();
    let mut vehicle = Vehicle::wheeled();
    vehicle.engine = VehicleEngineConfiguration::new(875.0, 900.0, 7_200.0, 0.5, 0.2);
    vehicle.transmission = VehicleTransmissionConfiguration::new(
        VehicleTransmissionMode::Manual,
        vec![3.1, 1.9, 1.2],
        vec![-3.0],
        0.5,
        0.3,
        0.5,
        4_000.0,
        2_000.0,
        14.0,
    );
    vehicle.max_pitch_roll_angle = std::f32::consts::FRAC_PI_2;
    original.set_component(vehicle.clone(), entity);

    let data = SceneSerializer::serialize(original.world()).expect("serialize");
    let mut restored = SceneRuntime::new(ComponentRegistry::built_in());
    SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");
    let restored_entity = restored.entities().first().copied().expect("entity");
    assert_eq!(
        restored.component::<Vehicle>(restored_entity),
        Some(vehicle)
    );
}

/// Tracked and motorcycle configurations survive a scene round-trip.
#[test]
fn controller_scene_round_trip() {
    for vehicle in [Vehicle::tracked_default(), Vehicle::motorcycle_default()] {
        let mut original = SceneRuntime::new(ComponentRegistry::built_in());
        let entity = original.create_entity();
        original.set_component(vehicle.clone(), entity);

        let data = SceneSerializer::serialize(original.world()).expect("serialize");
        let mut restored = SceneRuntime::new(ComponentRegistry::built_in());
        SceneSerializer::deserialize(&data, restored.world_mut()).expect("deserialize");
        let restored_entity = restored.entities().first().copied().expect("entity");
        assert_eq!(
            restored.component::<Vehicle>(restored_entity),
            Some(vehicle)
        );
    }
}
