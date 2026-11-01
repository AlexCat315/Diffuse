//! Ported from `Engine/Tests/SceneRuntimeTests/NativeCharacterControllerTests.swift`.
//!
//! Swift's `CharacterController()` / `CharacterCommand()` defaulted initializers are
//! `Default` in Rust, and the frame index that Swift's `tick(deltaTime:frameIndex:)`
//! passes is forwarded as-is.

use diffuse_math::simd::simd_compat::Float3;

use crate::components::core::registry::ComponentRegistry;
use crate::entity_id::EntityID;
use crate::physics::backend::physics_backend_kind::PhysicsBackendKind;
use crate::physics::character_controller::{
    CharacterCommand, CharacterController, CharacterGroundState, CharacterStance,
};
use crate::physics::collider::{Collider, ColliderShape};
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::physics_types::PhysicsSimulationMode;
use crate::runtime_world::LocalTransform;
use crate::scene_runtime::SceneRuntime;

fn make_scene(character_position: Float3) -> (SceneRuntime, EntityID) {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        backend_kind: PhysicsBackendKind::preferred(),
        fixed_time_step_seconds: 1.0 / 60.0,
        max_substeps_per_frame: 1,
        ..PhysicsSettingsResource::default()
    });

    let floor = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, -0.5, 0.0)),
        floor,
    );
    runtime.set_component(
        Collider::with_shape(ColliderShape::Box {
            half_extents: Float3::new(10.0, 0.5, 10.0),
            center: Float3::ZERO,
        }),
        floor,
    );

    let character = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(character_position),
        character,
    );
    runtime.set_component(CharacterController::default(), character);
    (runtime, character)
}

/// Native character falls onto the ground and reports support.
#[test]
fn lands_and_reports_ground_state() {
    let (mut runtime, character) = make_scene(Float3::new(0.0, 2.0, 0.0));
    for frame in 0..120 {
        runtime.submit_character_command(CharacterCommand::default(), character);
        runtime.tick(1.0 / 60.0, frame, Vec::new());
    }

    let state_frame = runtime.character_state_frame();
    let state = state_frame.states.get(&character);
    assert_eq!(state.map(|state| state.is_grounded()), Some(true));
    // Character transforms use a stable foot-space origin, independent of stance.
    assert!(state.map(|state| state.position.y).unwrap_or(1.0).abs() < 0.08);
    assert_eq!(
        runtime
            .world_transform(character)
            .map(|transform| transform.translation()),
        state.map(|state| state.position)
    );
    let debug_state = runtime
        .physics_debug_frame()
        .characters
        .into_iter()
        .find(|debug| debug.entity == character);
    assert_eq!(debug_state, state.copied());
    assert_eq!(
        debug_state.map(|debug| debug.ground_state),
        Some(CharacterGroundState::OnGround)
    );
}

/// Native character consumes the desired velocity of the current frame.
#[test]
fn moves_using_current_frame_command() {
    let (mut runtime, character) = make_scene(Float3::new(0.0, 1.0, 0.0));
    for frame in 0..90 {
        runtime.submit_character_command(CharacterCommand::default(), character);
        runtime.tick(1.0 / 60.0, frame, Vec::new());
    }
    let before = runtime
        .world_transform(character)
        .map(|transform| transform.translation().x)
        .unwrap_or(0.0);
    runtime.submit_character_command(
        CharacterCommand {
            desired_velocity: Float3::new(3.0, 0.0, 0.0),
            ..CharacterCommand::default()
        },
        character,
    );
    runtime.tick(1.0 / 60.0, 11, Vec::new());
    let after = runtime
        .world_transform(character)
        .map(|transform| transform.translation().x)
        .unwrap_or(0.0);
    assert!(after > before + 0.04);
}

/// Native character jumps and changes stance.
#[test]
fn jumps_and_crouches() {
    let (mut runtime, character) = make_scene(Float3::new(0.0, 1.0, 0.0));
    for frame in 0..90 {
        runtime.submit_character_command(CharacterCommand::default(), character);
        runtime.tick(1.0 / 60.0, frame, Vec::new());
    }
    let grounded_y = runtime
        .world_transform(character)
        .map(|transform| transform.translation().y)
        .unwrap_or(0.0);
    runtime.submit_character_command(
        CharacterCommand {
            jump_requested: true,
            jump_speed: 6.0,
            stance: CharacterStance::Crouching,
            ..CharacterCommand::default()
        },
        character,
    );
    runtime.tick(1.0 / 60.0, 11, Vec::new());
    let state_frame = runtime.character_state_frame();
    let state = state_frame.states.get(&character);
    assert!(state.map(|state| state.position.y).unwrap_or(0.0) > grounded_y);
    assert!(state.map(|state| state.linear_velocity.y).unwrap_or(0.0) > 0.0);
    assert_eq!(
        state.map(|state| state.stance),
        Some(CharacterStance::Crouching)
    );
}
