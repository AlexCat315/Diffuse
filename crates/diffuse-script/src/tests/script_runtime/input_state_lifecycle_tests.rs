//! Ported from `Engine/Tests/ScriptRuntimeTests/InputStateLifecycleTests.swift`.
//!
//! Swift's `SceneRuntime()` takes its component registry in Rust
//! (`SceneRuntime::new(ComponentRegistry::built_in())`), and its `tick(deltaTime:)`
//! gains the frame index and explicit event vector. `setScriptDriver(scripts)`
//! becomes `set_script_driver(Box::new(scripts))`.
//!
//! Swift's `InputActionMap()` is `InputActionMap::new(BTreeMap::new())`, and
//! `map.bind("jump", to: .key(Scancode.space))` becomes
//! `map.bind("jump", InputBinding::Key(Scancode::SPACE))`. The input event cases
//! keep their Swift names; only field labels change (`gamepadID` is
//! `gamepad_id`) and `KeyEvent(modifiers: [])` is `KeyModifiers::default()`.

use std::collections::BTreeMap;

use diffuse_kernel::input_event::{
    GamepadAxis, GamepadAxisEvent, GamepadButton, GamepadButtonEvent, InputEvent, KeyEvent,
    KeyModifiers, MouseButton, MouseButtonEvent,
};
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::input_action::{InputActionMap, InputBinding, InputFrameState, Scancode};
use diffuse_scene::scene_runtime::SceneRuntime;

use crate::core::script_runtime::ScriptRuntime;

/// Swift's `SceneRuntime()`; the Rust runtime takes its component registry.
fn scene() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

/// `Scancode.space` pressed for the first time.
fn space_down() -> InputEvent {
    InputEvent::KeyDown(KeyEvent {
        scancode: Scancode::SPACE,
        keycode: 0,
        modifiers: KeyModifiers::default(),
        is_repeat: false,
    })
}

/// `window focus loss releases held controls and clears axes`
#[test]
fn focus_loss_releases_held_controls() {
    let scripts = ScriptRuntime::new();
    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));

    let mut map = InputActionMap::new(BTreeMap::new());
    map.bind("jump", InputBinding::Key(Scancode::SPACE));
    map.bind("fire", InputBinding::MouseButton(MouseButton::Left));
    map.bind("dash", InputBinding::GamepadButton(GamepadButton::South));
    map.bind("move_x", InputBinding::GamepadAxis(GamepadAxis::LeftX));
    runtime.set_resource(map);

    runtime.tick(
        0.1,
        0,
        vec![
            space_down(),
            InputEvent::MouseButtonDown(MouseButtonEvent {
                button: MouseButton::Left,
                clicks: 1,
                ..Default::default()
            }),
            InputEvent::GamepadButtonDown(GamepadButtonEvent {
                gamepad_id: 7,
                button: GamepadButton::South,
            }),
            InputEvent::GamepadAxisMotion(GamepadAxisEvent {
                gamepad_id: 7,
                axis: GamepadAxis::LeftX,
                value: 0.75,
            }),
        ],
    );

    let active = runtime
        .resource::<InputFrameState>()
        .expect("the input processor must publish the frame state");
    assert!(active.is_held("jump"));
    assert!(active.is_held("fire"));
    assert!(active.is_held("dash"));
    assert_eq!(active.axis("move_x"), 0.75);

    runtime.tick(0.1, 1, vec![InputEvent::WindowFocusLost]);

    let released = runtime
        .resource::<InputFrameState>()
        .expect("the input processor must publish the frame state");
    assert!(!released.is_held("jump"));
    assert!(!released.is_held("fire"));
    assert!(!released.is_held("dash"));
    assert!(released.is_just_released("jump"));
    assert!(released.is_just_released("fire"));
    assert!(released.is_just_released("dash"));
    assert_eq!(released.axis("move_x"), 0.0);

    runtime.tick(0.1, 2, Vec::new());
    let next_frame = runtime
        .resource::<InputFrameState>()
        .expect("the input processor must publish the frame state");
    assert!(next_frame.just_released.is_empty());
    assert!(next_frame.held.is_empty());
    assert_eq!(next_frame.axis("move_x"), 0.0);
}

/// `window minimization also clears held controls`
#[test]
fn minimization_releases_held_controls() {
    let scripts = ScriptRuntime::new();
    let mut runtime = scene();
    runtime.set_script_driver(Box::new(scripts));

    let mut map = InputActionMap::new(BTreeMap::new());
    map.bind("jump", InputBinding::Key(Scancode::SPACE));
    runtime.set_resource(map);

    runtime.tick(0.1, 0, vec![space_down()]);
    runtime.tick(0.1, 1, vec![InputEvent::WindowMinimized]);

    let state = runtime
        .resource::<InputFrameState>()
        .expect("the input processor must publish the frame state");
    assert!(!state.is_held("jump"));
    assert!(state.is_just_released("jump"));
}
