//! Input event vocabulary re-exported from `cove-platform`, matching Swift's
//! `@_exported import CovePlatformCore` type aliases.

pub use cove_platform::{
    GamepadAxis, GamepadAxisEvent, GamepadButton, GamepadButtonEvent, InputEvent, KeyEvent,
    KeyModifiers, MouseButton, MouseButtonEvent, MouseMotionEvent, MouseWheelEvent,
    TextEditingEvent, TextInputArea, WindowId, WindowInputEvent,
};

/// Swift aliased `CovePlatformCore.WindowID`; Cove's Rust type is `WindowId`.
pub type WindowID = WindowId;
