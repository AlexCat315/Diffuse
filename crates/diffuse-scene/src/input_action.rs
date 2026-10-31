//! Input actions and their per-frame state.
//!
//! Ported from `SceneRuntime/InputAction.swift`. Bindings are authored as data
//! and evaluated each frame by the input processor, which writes an
//! [`InputFrameState`] resource for scripts to read.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_kernel::input_event::{GamepadAxis, GamepadButton, MouseButton};

/// SDL3 scancode constants.
///
/// Swift exposed these as `Scancode.a` and so on; Rust constants are
/// `SCREAMING_SNAKE_CASE`, so `Scancode::A`. The numeric values are SDL3's.
pub struct Scancode;

impl Scancode {
    // Letters.
    pub const A: u32 = 4;
    pub const B: u32 = 5;
    pub const C: u32 = 6;
    pub const D: u32 = 7;
    pub const E: u32 = 8;
    pub const F: u32 = 9;
    pub const G: u32 = 10;
    pub const H: u32 = 11;
    pub const I: u32 = 12;
    pub const J: u32 = 13;
    pub const K: u32 = 14;
    pub const L: u32 = 15;
    pub const M: u32 = 16;
    pub const N: u32 = 17;
    pub const O: u32 = 18;
    pub const P: u32 = 19;
    pub const Q: u32 = 20;
    pub const R: u32 = 21;
    pub const S: u32 = 22;
    pub const T: u32 = 23;
    pub const U: u32 = 24;
    pub const V: u32 = 25;
    pub const W: u32 = 26;
    pub const X: u32 = 27;
    pub const Y: u32 = 28;
    pub const Z: u32 = 29;

    // Numbers row.
    pub const NUM1: u32 = 30;
    pub const NUM2: u32 = 31;
    pub const NUM3: u32 = 32;
    pub const NUM4: u32 = 33;
    pub const NUM5: u32 = 34;
    pub const NUM6: u32 = 35;
    pub const NUM7: u32 = 36;
    pub const NUM8: u32 = 37;
    pub const NUM9: u32 = 38;
    pub const NUM0: u32 = 39;

    // Control.
    pub const RETURN: u32 = 40;
    pub const ESCAPE: u32 = 41;
    pub const BACKSPACE: u32 = 42;
    pub const TAB: u32 = 43;
    pub const SPACE: u32 = 44;

    // Arrows.
    pub const RIGHT: u32 = 79;
    pub const LEFT: u32 = 80;
    pub const DOWN: u32 = 81;
    pub const UP: u32 = 82;

    // Modifiers.
    pub const LCTRL: u32 = 224;
    pub const LSHIFT: u32 = 225;
    pub const LALT: u32 = 226;
    pub const RCTRL: u32 = 228;
    pub const RSHIFT: u32 = 229;
    pub const RALT: u32 = 230;

    // Function keys.
    pub const F1: u32 = 58;
    pub const F2: u32 = 59;
    pub const F3: u32 = 60;
    pub const F4: u32 = 61;
    pub const F5: u32 = 62;
    pub const F6: u32 = 63;
    pub const F7: u32 = 64;
    pub const F8: u32 = 65;
    pub const F9: u32 = 66;
    pub const F10: u32 = 67;
    pub const F11: u32 = 68;
    pub const F12: u32 = 69;
}

/// One physical input that can contribute to an action.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum InputBinding {
    /// A keyboard key identified by SDL scancode.
    Key(u32),
    /// A mouse button.
    MouseButton(MouseButton),
    /// A 1-D axis from two keys: negative key -> -1.0, positive key -> +1.0.
    KeyAxis { negative: u32, positive: u32 },
    /// Per-frame relative mouse movement, optionally gated by a held button.
    MouseMotion {
        axis: MouseMotionAxis,
        required_button: Option<MouseButton>,
        scale: f32,
    },
    /// Per-frame mouse wheel delta.
    MouseWheel { axis: MouseWheelAxis, scale: f32 },
    /// A gamepad button.
    GamepadButton(GamepadButton),
    /// A gamepad axis (stick or trigger).
    GamepadAxis(GamepadAxis),
}

impl InputBinding {
    /// `case mouseMotion(axis:)` — no required button, unit scale.
    pub fn mouse_motion(axis: MouseMotionAxis) -> Self {
        InputBinding::MouseMotion {
            axis,
            required_button: None,
            scale: 1.0,
        }
    }

    /// `case mouseMotion(axis:requiredButton:scale:)`.
    pub fn mouse_motion_with(
        axis: MouseMotionAxis,
        required_button: Option<MouseButton>,
        scale: f32,
    ) -> Self {
        InputBinding::MouseMotion {
            axis,
            required_button,
            scale,
        }
    }

    /// `case mouseWheel(axis:)` — unit scale.
    pub fn mouse_wheel(axis: MouseWheelAxis) -> Self {
        InputBinding::MouseWheel { axis, scale: 1.0 }
    }

    /// `case mouseWheel(axis:scale:)`.
    pub fn mouse_wheel_with(axis: MouseWheelAxis, scale: f32) -> Self {
        InputBinding::MouseWheel { axis, scale }
    }
}

/// Which relative mouse axis a binding reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MouseMotionAxis {
    X,
    Y,
}

impl MouseMotionAxis {
    /// The `String` raw value Swift's `RawRepresentable` conformance used.
    pub const fn raw_value(&self) -> &'static str {
        match self {
            MouseMotionAxis::X => "x",
            MouseMotionAxis::Y => "y",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "x" => Some(MouseMotionAxis::X),
            "y" => Some(MouseMotionAxis::Y),
            _ => None,
        }
    }
}

/// Which mouse wheel axis a binding reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MouseWheelAxis {
    X,
    Y,
}

impl MouseWheelAxis {
    /// The `String` raw value Swift's `RawRepresentable` conformance used.
    pub const fn raw_value(&self) -> &'static str {
        match self {
            MouseWheelAxis::X => "x",
            MouseWheelAxis::Y => "y",
        }
    }

    pub fn from_raw_value(value: &str) -> Option<Self> {
        match value {
            "x" => Some(MouseWheelAxis::X),
            "y" => Some(MouseWheelAxis::Y),
            _ => None,
        }
    }
}

/// Maps logical action names to one or more physical [`InputBinding`]s.
///
/// Store this as a scene resource. Bindings are evaluated each frame by the
/// input state processor, which writes [`InputFrameState`].
#[derive(Clone, Debug, PartialEq, Default)]
pub struct InputActionMap {
    pub bindings: BTreeMap<String, Vec<InputBinding>>,
}

impl InputActionMap {
    /// `init(bindings:)` — Swift's default is an empty dictionary.
    pub fn new(bindings: BTreeMap<String, Vec<InputBinding>>) -> Self {
        InputActionMap { bindings }
    }

    /// Append a binding, preserving earlier bindings for the same action.
    pub fn bind(&mut self, action: &str, binding: InputBinding) {
        self.bindings
            .entry(action.to_string())
            .or_default()
            .push(binding);
    }

    /// Remove every binding for `action`.
    pub fn unbind(&mut self, action: &str) {
        self.bindings.remove(action);
    }
}

/// Per-frame input state derived from the current [`InputActionMap`].
///
/// Written each frame before scripts run and read through the script context.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct InputFrameState {
    /// Actions that are currently held down (pressed this frame or earlier).
    pub held: BTreeSet<String>,
    /// Actions whose button was pressed this frame (leading edge).
    pub just_pressed: BTreeSet<String>,
    /// Actions whose button was released this frame (trailing edge).
    pub just_released: BTreeSet<String>,
    /// Axis values. Key/gamepad values are normalized; relative mouse and wheel
    /// bindings retain their scaled per-frame deltas.
    pub axes: BTreeMap<String, f32>,
}

impl InputFrameState {
    /// `init(held:justPressed:justReleased:axes:)` with Swift's defaults.
    pub fn new(
        held: BTreeSet<String>,
        just_pressed: BTreeSet<String>,
        just_released: BTreeSet<String>,
        axes: BTreeMap<String, f32>,
    ) -> Self {
        InputFrameState {
            held,
            just_pressed,
            just_released,
            axes,
        }
    }

    pub fn is_held(&self, action: &str) -> bool {
        self.held.contains(action)
    }

    pub fn is_just_pressed(&self, action: &str) -> bool {
        self.just_pressed.contains(action)
    }

    pub fn is_just_released(&self, action: &str) -> bool {
        self.just_released.contains(action)
    }

    /// The axis value for `action`, or `0` when the action has no axis.
    pub fn axis(&self, action: &str) -> f32 {
        self.axes.get(action).copied().unwrap_or(0.0)
    }
}
