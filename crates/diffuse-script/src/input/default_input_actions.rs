//! Standard character and camera bindings, exposed as a Rust extension trait.

use diffuse_kernel::input_event::{GamepadAxis, GamepadButton, MouseButton};
use diffuse_scene::input_action::{
    InputActionMap, InputBinding, MouseMotionAxis, MouseWheelAxis, Scancode,
};

pub trait DefaultInputActions {
    fn cove_default() -> Self;
}

impl DefaultInputActions for InputActionMap {
    fn cove_default() -> Self {
        let mut map = Self::default();
        for (action, first, second, button) in [
            (
                "move_forward",
                Scancode::W,
                Scancode::UP,
                GamepadButton::DpadUp,
            ),
            (
                "move_back",
                Scancode::S,
                Scancode::DOWN,
                GamepadButton::DpadDown,
            ),
            (
                "move_left",
                Scancode::A,
                Scancode::LEFT,
                GamepadButton::DpadLeft,
            ),
            (
                "move_right",
                Scancode::D,
                Scancode::RIGHT,
                GamepadButton::DpadRight,
            ),
        ] {
            map.bind(action, InputBinding::Key(first));
            map.bind(action, InputBinding::Key(second));
            map.bind(action, InputBinding::GamepadButton(button));
        }
        map.bind("move_up", InputBinding::Key(Scancode::E));
        map.bind("move_down", InputBinding::Key(Scancode::Q));
        map.bind(
            "move_x",
            InputBinding::KeyAxis {
                negative: Scancode::A,
                positive: Scancode::D,
            },
        );
        map.bind(
            "move_y",
            InputBinding::KeyAxis {
                negative: Scancode::S,
                positive: Scancode::W,
            },
        );
        map.bind("jump", InputBinding::Key(Scancode::SPACE));
        map.bind("jump", InputBinding::GamepadButton(GamepadButton::South));
        map.bind("crouch", InputBinding::Key(Scancode::LCTRL));
        map.bind("crouch", InputBinding::GamepadButton(GamepadButton::East));
        for (x, y) in [("look_x", "look_y"), ("orbit_x", "orbit_y")] {
            map.bind(
                x,
                InputBinding::mouse_motion_with(MouseMotionAxis::X, Some(MouseButton::Right), 1.0),
            );
            map.bind(
                y,
                InputBinding::mouse_motion_with(MouseMotionAxis::Y, Some(MouseButton::Right), 1.0),
            );
            map.bind(x, InputBinding::GamepadAxis(GamepadAxis::RightX));
            map.bind(y, InputBinding::GamepadAxis(GamepadAxis::RightY));
        }
        map.bind("camera_zoom", InputBinding::mouse_wheel(MouseWheelAxis::Y));
        map
    }
}
