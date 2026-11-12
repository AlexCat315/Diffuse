//! Ported from `Editor/Tests/EditorCoreTests/InputStateTests.swift`.

#[test]
fn precise_scroll_units_keep_editor_camera_line_sensitivity() {
    use cove_platform::{ScrollDevice, ScrollInput, ScrollUnit};
    use diffuse_kernel::input_event::{InputEvent, MouseWheelEvent};

    use crate::input::input_state::InputState;

    let mut state = InputState::new();
    state.process(&[InputEvent::MouseWheel(MouseWheelEvent {
        x: 5.0,
        y: -20.0,
        input: ScrollInput {
            unit: ScrollUnit::Points,
            device: ScrollDevice::Continuous,
            ..ScrollInput::default()
        },
        ..MouseWheelEvent::default()
    })]);
    assert_eq!(state.scroll_delta_x, 0.5);
    assert_eq!(state.scroll_delta_y, -2.0);

    state.process(&[InputEvent::MouseWheel(MouseWheelEvent {
        x: 0.5,
        y: -2.0,
        ..MouseWheelEvent::default()
    })]);
    assert_eq!(state.scroll_delta_x, 0.5);
    assert_eq!(state.scroll_delta_y, -2.0);
}

#[test]
fn focus_loss_clears_held_controls_modifiers_and_transient_deltas() {
    use cove_ui_compose::Scancode;
    use diffuse_kernel::input_event::{
        InputEvent, KeyEvent, KeyModifiers, MouseButton, MouseButtonEvent, MouseMotionEvent,
        MouseWheelEvent,
    };

    use crate::input::input_state::InputState;

    let mut state = InputState::new();
    state.process(&[
        InputEvent::KeyDown(KeyEvent {
            scancode: Scancode::SPACE,
            keycode: 0,
            modifiers: KeyModifiers::LEFT_SHIFT,
            is_repeat: false,
        }),
        InputEvent::MouseButtonDown(MouseButtonEvent {
            button: MouseButton::Left,
            x: 12.0,
            y: 24.0,
            clicks: 1,
            ..MouseButtonEvent::default()
        }),
        InputEvent::MouseMotion(MouseMotionEvent {
            x: 14.0,
            y: 25.0,
            delta_x: 2.0,
            delta_y: 1.0,
            ..MouseMotionEvent::default()
        }),
        InputEvent::MouseWheel(MouseWheelEvent {
            x: 1.0,
            y: -2.0,
            ..MouseWheelEvent::default()
        }),
        InputEvent::WindowFocusLost,
    ]);

    assert!(state.pressed_keys.is_empty());
    assert!(state.pressed_mouse_buttons.is_empty());
    assert!(state.modifiers.is_empty());
    assert_eq!(state.mouse_delta_x, 0.0);
    assert_eq!(state.mouse_delta_y, 0.0);
    assert_eq!(state.scroll_delta_x, 0.0);
    assert_eq!(state.scroll_delta_y, 0.0);
}

#[test]
fn minimization_clears_held_controls() {
    use cove_ui_compose::Scancode;
    use diffuse_kernel::input_event::{
        InputEvent, KeyEvent, KeyModifiers, MouseButton, MouseButtonEvent,
    };

    use crate::input::input_state::InputState;

    let mut state = InputState::new();
    state.process(&[
        InputEvent::KeyDown(KeyEvent {
            scancode: Scancode::SPACE,
            keycode: 0,
            modifiers: KeyModifiers::default(),
            is_repeat: false,
        }),
        InputEvent::MouseButtonDown(MouseButtonEvent {
            button: MouseButton::Right,
            x: 0.0,
            y: 0.0,
            clicks: 1,
            ..MouseButtonEvent::default()
        }),
        InputEvent::WindowMinimized,
    ]);

    assert!(!state.is_key_pressed(Scancode::SPACE));
    assert!(!state.is_mouse_button_pressed(MouseButton::Right));
}
