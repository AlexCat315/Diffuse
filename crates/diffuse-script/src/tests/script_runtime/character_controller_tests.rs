//! Ported from `Engine/Tests/ScriptRuntimeTests/CharacterControllerTests.swift`.
//!
//! Swift's `tick(deltaTime:inputEvents:)` gains the frame index in Rust; every call
//! here advances it. `ScriptComponent(ScriptBinding(handle, parametersJSON:))`
//! becomes an explicit `ScriptBinding`.

use diffuse_kernel::input_event::{InputEvent, KeyEvent, KeyModifiers};
use diffuse_math::simd::simd_compat::Float3;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::input_action::{InputActionMap, InputBinding, Scancode};
use diffuse_scene::physics::backend::physics_backend_kind::PhysicsBackendKind;
use diffuse_scene::physics::character_controller::CharacterController;
use diffuse_scene::physics::collider::{Collider, ColliderShape};
use diffuse_scene::physics::physics_settings::PhysicsSettingsResource;
use diffuse_scene::physics::physics_types::PhysicsSimulationMode;
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::controllers::character_input_controller::{
    CharacterLandEvent, CharacterLeaveGroundEvent,
};
use crate::core::script_component::{ScriptBinding, ScriptBindingID, ScriptComponent};
use crate::core::script_lifecycle::Script;
use crate::core::script_runtime::ScriptRuntime;

fn key_down(scancode: u32) -> InputEvent {
    InputEvent::KeyDown(KeyEvent {
        scancode,
        keycode: scancode,
        modifiers: KeyModifiers::default(),
        is_repeat: false,
    })
}

fn key_up(scancode: u32) -> InputEvent {
    InputEvent::KeyUp(KeyEvent {
        scancode,
        keycode: scancode,
        modifiers: KeyModifiers::default(),
        is_repeat: false,
    })
}

fn make_scene(parameters_json: &str) -> (SceneRuntime, diffuse_scene::entity_id::EntityID) {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    let scripts = ScriptRuntime::new();
    runtime.set_script_driver(Box::new(scripts.clone()));
    runtime.set_physics_settings(PhysicsSettingsResource {
        simulation_mode: PhysicsSimulationMode::Play,
        backend_kind: PhysicsBackendKind::Natsel,
        fixed_time_step_seconds: 1.0 / 60.0,
        max_substeps_per_frame: 60,
        ..PhysicsSettingsResource::default()
    });
    let cc_script = scripts.register(Script::character_input_controller(), None);
    let entity = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, 5.0, 0.0)),
        entity,
    );
    runtime.set_component(
        CharacterController {
            layer_id: 1,
            ..CharacterController::default()
        },
        entity,
    );
    runtime.set_component(
        ScriptComponent::new(vec![ScriptBinding::new(
            cc_script,
            ScriptBindingID::new(),
            None,
            true,
            parameters_json,
        )]),
        entity,
    );

    let mut map = InputActionMap::default();
    map.bind("move_forward", InputBinding::Key(Scancode::W));
    map.bind("move_back", InputBinding::Key(Scancode::S));
    map.bind("move_left", InputBinding::Key(Scancode::A));
    map.bind("move_right", InputBinding::Key(Scancode::D));
    map.bind("jump", InputBinding::Key(Scancode::SPACE));
    runtime.set_resource(map);

    (runtime, entity)
}

fn add_ground(runtime: &mut SceneRuntime, y: f32) {
    let ground = runtime.create_entity();
    runtime.set_local_transform(
        LocalTransform::from_translation(Float3::new(0.0, y - 0.5, 0.0)),
        ground,
    );
    let mut collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::new(10.0, 0.5, 10.0),
        center: Float3::ZERO,
    });
    collider.layer_id = 1;
    collider.layer_mask = u16::MAX;
    runtime.set_component(collider, ground);
}

fn add_wall(runtime: &mut SceneRuntime, position: Float3) {
    let wall = runtime.create_entity();
    runtime.set_local_transform(LocalTransform::from_translation(position), wall);
    let mut collider = Collider::with_shape(ColliderShape::Box {
        half_extents: Float3::new(2.0, 2.0, 0.5),
        center: Float3::ZERO,
    });
    collider.layer_id = 1;
    collider.layer_mask = u16::MAX;
    runtime.set_component(collider, wall);
}

fn tick(runtime: &mut SceneRuntime, frame: u64, delta: f64, events: Vec<InputEvent>) {
    runtime.tick(delta, frame, events);
}

fn translation(runtime: &SceneRuntime, entity: diffuse_scene::entity_id::EntityID) -> Float3 {
    runtime
        .local_transform(entity)
        .map(|transform| transform.translation())
        .expect("entity must keep a local transform")
}

/// Gravity pulls the entity downward when airborne.
#[test]
fn gravity_pulls_down() {
    let (mut runtime, entity) = make_scene("{}");
    tick(&mut runtime, 0, 0.1, Vec::new());
    assert!(translation(&runtime, entity).y < 5.0);
}

/// The entity lands on the ground and stops.
#[test]
fn lands_on_ground() {
    let (mut runtime, entity) = make_scene("{}");
    add_ground(&mut runtime, 0.0);
    for frame in 0..100 {
        tick(&mut runtime, frame, 0.1, Vec::new());
    }
    assert!(translation(&runtime, entity).y.abs() < 0.1);
}

/// The entity does not fall through the ground.
#[test]
fn does_not_fall_through_ground() {
    let (mut runtime, entity) = make_scene("{}");
    add_ground(&mut runtime, 0.0);
    for frame in 0..150 {
        tick(&mut runtime, frame, 0.1, Vec::new());
    }
    assert!(translation(&runtime, entity).y >= -0.1);
}

/// Jumping lifts the entity upward.
#[test]
fn jump_lifts_upward() {
    let (mut runtime, entity) = make_scene("{}");
    add_ground(&mut runtime, 0.0);
    for frame in 0..100 {
        tick(&mut runtime, frame, 0.1, Vec::new());
    }
    let landed_y = translation(&runtime, entity).y;
    tick(&mut runtime, 100, 0.05, vec![key_down(Scancode::SPACE)]);
    tick(&mut runtime, 101, 0.1, vec![key_up(Scancode::SPACE)]);
    assert!(translation(&runtime, entity).y > landed_y + 0.1);
}

/// `move_forward` moves in -Z.
#[test]
fn move_forward() {
    let (mut runtime, entity) = make_scene("{}");
    add_ground(&mut runtime, 0.0);
    for frame in 0..100 {
        tick(&mut runtime, frame, 0.1, Vec::new());
    }
    tick(&mut runtime, 100, 0.5, vec![key_down(Scancode::W)]);
    assert!(translation(&runtime, entity).z < -0.5);
}

/// `move_forward` sweeps against walls.
#[test]
fn move_forward_sweeps_against_walls() {
    let (mut runtime, entity) = make_scene("{}");
    add_ground(&mut runtime, 0.0);
    add_wall(&mut runtime, Float3::new(0.0, 2.0, -2.0));
    for frame in 0..100 {
        tick(&mut runtime, frame, 0.1, Vec::new());
    }
    tick(&mut runtime, 100, 0.5, vec![key_down(Scancode::W)]);
    assert!(translation(&runtime, entity).z > -1.2);
}

/// Diagonal movement slides along walls.
#[test]
fn diagonal_movement_slides_along_walls() {
    let (mut runtime, entity) = make_scene("{}");
    add_ground(&mut runtime, 0.0);
    add_wall(&mut runtime, Float3::new(0.0, 2.0, -2.0));
    for frame in 0..100 {
        tick(&mut runtime, frame, 0.1, Vec::new());
    }
    tick(
        &mut runtime,
        100,
        0.5,
        vec![key_down(Scancode::W), key_down(Scancode::D)],
    );
    let position = translation(&runtime, entity);
    assert!(position.z > -1.2);
    assert!(position.x > 1.2);
}

/// `move_left` moves in -X.
#[test]
fn move_left() {
    let (mut runtime, entity) = make_scene("{}");
    add_ground(&mut runtime, 0.0);
    for frame in 0..100 {
        tick(&mut runtime, frame, 0.1, Vec::new());
    }
    tick(&mut runtime, 100, 0.5, vec![key_down(Scancode::A)]);
    assert!(translation(&runtime, entity).x < -0.5);
}

/// `CharacterLandEvent` fires on landing.
#[test]
fn land_event_fires() {
    let (mut runtime, _) = make_scene("{}");
    add_ground(&mut runtime, 0.0);
    for frame in 0..100 {
        tick(&mut runtime, frame, 0.1, Vec::new());
    }
    assert!(runtime.resource::<CharacterLandEvent>().is_some());
}

/// `CharacterLeaveGroundEvent` fires on jump.
#[test]
fn leave_ground_event_fires() {
    let (mut runtime, _) = make_scene("{}");
    add_ground(&mut runtime, 0.0);
    for frame in 0..100 {
        tick(&mut runtime, frame, 0.1, Vec::new());
    }
    tick(&mut runtime, 100, 0.05, vec![key_down(Scancode::SPACE)]);
    tick(&mut runtime, 101, 0.1, Vec::new());
    assert!(runtime.resource::<CharacterLeaveGroundEvent>().is_some());
}
