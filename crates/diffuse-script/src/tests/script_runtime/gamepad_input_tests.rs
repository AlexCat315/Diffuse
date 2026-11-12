//! Ported from `Engine/Tests/ScriptRuntimeTests/GamepadInputTests.swift`.
//!
//! Swift's `tick(deltaTime:inputEvents:)` gains the frame index in Rust.

use diffuse_kernel::input_event::{
    GamepadAxis, GamepadAxisEvent, GamepadButton, GamepadButtonEvent, InputEvent, MouseButton,
    MouseButtonEvent, MouseMotionEvent, MouseWheelEvent,
};
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::input_action::{
    InputActionMap, InputBinding, InputFrameState, MouseMotionAxis, MouseWheelAxis, Scancode,
};
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::core::script_component::ScriptComponent;
use crate::core::script_runtime::ScriptRuntime;
use crate::input::default_input_actions::DefaultInputActions;

fn make_scene() -> SceneRuntime {
    let mut runtime = SceneRuntime::new(ComponentRegistry::built_in());
    let scripts = ScriptRuntime::new();
    runtime.set_script_driver(Box::new(scripts));
    let entity = runtime.create_entity();
    runtime.set_component(ScriptComponent::new(Vec::new()), entity);
    runtime
}

fn tick(runtime: &mut SceneRuntime, frame: u64, events: Vec<InputEvent>) {
    runtime.tick(0.1, frame, events);
}

fn button_event(button: GamepadButton) -> InputEvent {
    InputEvent::GamepadButtonDown(GamepadButtonEvent {
        gamepad_id: 0,
        button,
    })
}

fn axis_event(axis: GamepadAxis, value: f32) -> InputEvent {
    InputEvent::GamepadAxisMotion(GamepadAxisEvent {
        gamepad_id: 0,
        axis,
        value,
    })
}

/// A gamepad button binding triggers the action held state.
#[test]
fn gamepad_button_triggers_held() {
    let mut runtime = make_scene();
    let mut map = InputActionMap::default();
    map.bind("jump", InputBinding::GamepadButton(GamepadButton::South));
    runtime.set_resource(map);

    tick(&mut runtime, 0, vec![button_event(GamepadButton::South)]);

    let state = runtime
        .resource::<InputFrameState>()
        .expect("input frame state");
    assert!(state.is_held("jump"));
}

/// Releasing a gamepad button clears the action.
#[test]
fn gamepad_button_release_clears_action() {
    let mut runtime = make_scene();
    let mut map = InputActionMap::default();
    map.bind("jump", InputBinding::GamepadButton(GamepadButton::South));
    runtime.set_resource(map);

    tick(&mut runtime, 0, vec![button_event(GamepadButton::South)]);
    tick(
        &mut runtime,
        1,
        vec![InputEvent::GamepadButtonUp(GamepadButtonEvent {
            gamepad_id: 0,
            button: GamepadButton::South,
        })],
    );

    let state = runtime
        .resource::<InputFrameState>()
        .expect("input frame state");
    assert!(!state.is_held("jump"));
}

/// `just_pressed` fires on the first frame only.
#[test]
fn gamepad_button_just_pressed() {
    let mut runtime = make_scene();
    let mut map = InputActionMap::default();
    map.bind("fire", InputBinding::GamepadButton(GamepadButton::West));
    runtime.set_resource(map);

    tick(&mut runtime, 0, vec![button_event(GamepadButton::West)]);
    assert!(
        runtime
            .resource::<InputFrameState>()
            .expect("input frame state")
            .is_just_pressed("fire")
    );

    tick(&mut runtime, 1, Vec::new());
    let state = runtime
        .resource::<InputFrameState>()
        .expect("input frame state");
    assert!(!state.is_just_pressed("fire"));
    assert!(state.is_held("fire"));
}

/// The left stick maps to axis actions.
#[test]
fn gamepad_left_stick_axis() {
    let mut runtime = make_scene();
    let mut map = InputActionMap::default();
    map.bind("move_x", InputBinding::GamepadAxis(GamepadAxis::LeftX));
    map.bind("move_y", InputBinding::GamepadAxis(GamepadAxis::LeftY));
    runtime.set_resource(map);

    tick(
        &mut runtime,
        0,
        vec![
            axis_event(GamepadAxis::LeftX, 0.75),
            axis_event(GamepadAxis::LeftY, -0.5),
        ],
    );

    let state = runtime
        .resource::<InputFrameState>()
        .expect("input frame state");
    assert!((state.axis("move_x") - 0.75).abs() < 0.01);
    assert!((state.axis("move_y") + 0.5).abs() < 0.01);
}

/// The trigger axis maps correctly.
#[test]
fn trigger_axis() {
    let mut runtime = make_scene();
    let mut map = InputActionMap::default();
    map.bind(
        "accelerate",
        InputBinding::GamepadAxis(GamepadAxis::RightTrigger),
    );
    runtime.set_resource(map);

    tick(
        &mut runtime,
        0,
        vec![axis_event(GamepadAxis::RightTrigger, 0.85)],
    );

    let state = runtime
        .resource::<InputFrameState>()
        .expect("input frame state");
    assert!((state.axis("accelerate") - 0.85).abs() < 0.01);
}

/// Keyboard and gamepad both contribute to the same action.
#[test]
fn mixed_bindings_contribute() {
    let mut runtime = make_scene();
    let mut map = InputActionMap::default();
    map.bind("jump", InputBinding::Key(Scancode::SPACE));
    map.bind("jump", InputBinding::GamepadButton(GamepadButton::South));
    runtime.set_resource(map);

    tick(&mut runtime, 0, vec![button_event(GamepadButton::South)]);

    let state = runtime
        .resource::<InputFrameState>()
        .expect("input frame state");
    assert!(state.is_held("jump"));
    assert!(state.is_just_pressed("jump"));
}

/// Axis bindings accumulate from multiple sources.
#[test]
fn axis_accumulates() {
    let mut runtime = make_scene();
    let mut map = InputActionMap::default();
    map.bind("look_x", InputBinding::GamepadAxis(GamepadAxis::RightX));
    map.bind(
        "look_x",
        InputBinding::KeyAxis {
            negative: Scancode::LEFT,
            positive: Scancode::RIGHT,
        },
    );
    runtime.set_resource(map);

    tick(&mut runtime, 0, vec![axis_event(GamepadAxis::RightX, 0.3)]);

    let state = runtime
        .resource::<InputFrameState>()
        .expect("input frame state");
    assert!((state.axis("look_x") - 0.3).abs() < 0.01);
}

/// Mouse motion axes honor required button gates.
#[test]
fn mouse_motion_button_gate() {
    let mut runtime = make_scene();
    let mut map = InputActionMap::default();
    map.bind(
        "look_x",
        InputBinding::mouse_motion_with(MouseMotionAxis::X, Some(MouseButton::Right), 0.5),
    );
    runtime.set_resource(map);

    tick(
        &mut runtime,
        0,
        vec![InputEvent::MouseMotion(MouseMotionEvent {
            x: 10.0,
            y: 0.0,
            delta_x: 10.0,
            delta_y: 0.0,
            ..MouseMotionEvent::default()
        })],
    );
    assert_eq!(
        runtime
            .resource::<InputFrameState>()
            .map(|state| state.axis("look_x")),
        Some(0.0)
    );

    tick(
        &mut runtime,
        1,
        vec![
            InputEvent::MouseButtonDown(MouseButtonEvent {
                button: MouseButton::Right,
                clicks: 1,
                ..MouseButtonEvent::default()
            }),
            InputEvent::MouseMotion(MouseMotionEvent {
                x: 18.0,
                y: 0.0,
                delta_x: 8.0,
                delta_y: 0.0,
                ..MouseMotionEvent::default()
            }),
        ],
    );
    assert_eq!(
        runtime
            .resource::<InputFrameState>()
            .map(|state| state.axis("look_x")),
        Some(4.0)
    );
}

/// Mouse wheel contributes a per-frame camera axis.
#[test]
fn mouse_wheel_axis() {
    let mut runtime = make_scene();
    let mut map = InputActionMap::default();
    map.bind(
        "camera_zoom",
        InputBinding::mouse_wheel_with(MouseWheelAxis::Y, -2.0),
    );
    runtime.set_resource(map);

    tick(
        &mut runtime,
        0,
        vec![InputEvent::MouseWheel(MouseWheelEvent {
            x: 0.0,
            y: 1.5,
            ..MouseWheelEvent::default()
        })],
    );
    assert_eq!(
        runtime
            .resource::<InputFrameState>()
            .map(|state| state.axis("camera_zoom")),
        Some(-3.0)
    );
    tick(&mut runtime, 1, Vec::new());
    assert_eq!(
        runtime
            .resource::<InputFrameState>()
            .map(|state| state.axis("camera_zoom")),
        Some(0.0)
    );
}

/// The Cove defaults cover movement, camera and jump actions.
#[test]
fn standard_input_map() {
    let map = InputActionMap::cove_default();
    assert!(
        map.bindings
            .get("move_forward")
            .is_some_and(|bindings| bindings.contains(&InputBinding::Key(Scancode::W)))
    );
    assert!(
        map.bindings
            .get("jump")
            .is_some_and(|bindings| bindings.contains(&InputBinding::Key(Scancode::SPACE)))
    );
    assert!(map.bindings.get("look_x").is_some_and(|bindings| {
        bindings.contains(&InputBinding::mouse_motion_with(
            MouseMotionAxis::X,
            Some(MouseButton::Right),
            1.0,
        ))
    }));
    assert!(map.bindings.get("camera_zoom").is_some_and(|bindings| {
        bindings.contains(&InputBinding::mouse_wheel_with(MouseWheelAxis::Y, 1.0))
    }));
}
