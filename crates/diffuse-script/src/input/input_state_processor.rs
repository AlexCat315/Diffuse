//! Input edge state, persistent held inputs and per-frame relative axes.

use diffuse_kernel::input_event::{GamepadAxis, GamepadButton, InputEvent, MouseButton};
use diffuse_scene::input_action::{
    InputActionMap, InputBinding, InputFrameState, MouseMotionAxis, MouseWheelAxis,
};
use diffuse_scene::scene_runtime::InputFrameResource;
use diffuse_scene::scripting::RuntimeScriptPhaseContext;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

#[derive(Default)]
pub(crate) struct InputStateProcessor {
    held_keys: HashSet<u32>,
    held_mouse_buttons: HashSet<MouseButton>,
    held_gamepad_buttons: HashSet<GamepadButton>,
    gamepad_axes: HashMap<GamepadAxis, f32>,
}

impl InputStateProcessor {
    pub(crate) fn process(&mut self, context: &mut RuntimeScriptPhaseContext<'_>) {
        let frame = context.resource::<InputFrameResource>().unwrap_or_default();
        let map = context.resource::<InputActionMap>().unwrap_or_default();
        let mut keys_pressed = HashSet::new();
        let mut keys_released = HashSet::new();
        let mut buttons_pressed = HashSet::new();
        let mut buttons_released = HashSet::new();
        let mut gamepad_pressed = HashSet::new();
        let mut gamepad_released = HashSet::new();
        let (mut mouse_x, mut mouse_y, mut wheel_x, mut wheel_y) =
            (0.0_f32, 0.0_f32, 0.0_f32, 0.0_f32);
        for event in frame.events {
            match event {
                InputEvent::KeyDown(event) if !event.is_repeat => {
                    keys_pressed.insert(event.scancode);
                    self.held_keys.insert(event.scancode);
                }
                InputEvent::KeyUp(event) => {
                    keys_released.insert(event.scancode);
                    self.held_keys.remove(&event.scancode);
                }
                InputEvent::MouseButtonDown(event) => {
                    buttons_pressed.insert(event.button);
                    self.held_mouse_buttons.insert(event.button);
                }
                InputEvent::MouseButtonUp(event) => {
                    buttons_released.insert(event.button);
                    self.held_mouse_buttons.remove(&event.button);
                }
                InputEvent::GamepadButtonDown(event) => {
                    gamepad_pressed.insert(event.button);
                    self.held_gamepad_buttons.insert(event.button);
                }
                InputEvent::GamepadButtonUp(event) => {
                    gamepad_released.insert(event.button);
                    self.held_gamepad_buttons.remove(&event.button);
                }
                InputEvent::GamepadAxisMotion(event) => {
                    self.gamepad_axes.insert(event.axis, event.value);
                }
                InputEvent::MouseMotion(event) => {
                    mouse_x += event.delta_x;
                    mouse_y += event.delta_y;
                }
                InputEvent::MouseWheel(event) => {
                    let (x, y) = event.displacement(10.0, 30.0, 30.0);
                    wheel_x += x / 10.0;
                    wheel_y += y / 10.0;
                }
                InputEvent::WindowFocusLost | InputEvent::WindowMinimized => {
                    keys_released.extend(&self.held_keys);
                    buttons_released.extend(&self.held_mouse_buttons);
                    gamepad_released.extend(&self.held_gamepad_buttons);
                    self.held_keys.clear();
                    self.held_mouse_buttons.clear();
                    self.held_gamepad_buttons.clear();
                    self.gamepad_axes.clear();
                }
                _ => {}
            }
        }
        let mut held = BTreeSet::new();
        let mut just_pressed = BTreeSet::new();
        let mut just_released = BTreeSet::new();
        let mut axes = BTreeMap::new();
        for (action, bindings) in map.bindings {
            let (mut is_held, mut was_pressed, mut was_released) = (false, false, false);
            for binding in bindings {
                match binding {
                    InputBinding::Key(scancode) => {
                        is_held |= self.held_keys.contains(&scancode);
                        was_pressed |= keys_pressed.contains(&scancode);
                        was_released |= keys_released.contains(&scancode);
                    }
                    InputBinding::MouseButton(button) => {
                        is_held |= self.held_mouse_buttons.contains(&button);
                        was_pressed |= buttons_pressed.contains(&button);
                        was_released |= buttons_released.contains(&button);
                    }
                    InputBinding::GamepadButton(button) => {
                        is_held |= self.held_gamepad_buttons.contains(&button);
                        was_pressed |= gamepad_pressed.contains(&button);
                        was_released |= gamepad_released.contains(&button);
                    }
                    InputBinding::KeyAxis { negative, positive } => {
                        let n = if self.held_keys.contains(&negative) {
                            -1.0_f32
                        } else {
                            0.0
                        };
                        let p = if self.held_keys.contains(&positive) {
                            1.0_f32
                        } else {
                            0.0
                        };
                        *axes.entry(action.clone()).or_insert(0.0) += (p + n).clamp(-1.0, 1.0);
                    }
                    InputBinding::MouseMotion {
                        axis,
                        required_button,
                        scale,
                    } => {
                        if !required_button
                            .is_none_or(|button| self.held_mouse_buttons.contains(&button))
                        {
                            continue;
                        }
                        let value = if axis == MouseMotionAxis::X {
                            mouse_x
                        } else {
                            mouse_y
                        };
                        *axes.entry(action.clone()).or_insert(0.0) += value * scale;
                    }
                    InputBinding::MouseWheel { axis, scale } => {
                        let value = if axis == MouseWheelAxis::X {
                            wheel_x
                        } else {
                            wheel_y
                        };
                        *axes.entry(action.clone()).or_insert(0.0) += value * scale;
                    }
                    InputBinding::GamepadAxis(axis) => {
                        *axes.entry(action.clone()).or_insert(0.0) +=
                            self.gamepad_axes.get(&axis).copied().unwrap_or(0.0);
                    }
                }
            }
            if is_held {
                held.insert(action.clone());
            }
            if was_pressed {
                just_pressed.insert(action.clone());
            }
            if was_released {
                just_released.insert(action);
            }
        }
        context.set_resource(InputFrameState::new(
            held,
            just_pressed,
            just_released,
            axes,
        ));
    }

    pub(crate) fn reset(&mut self) {
        self.held_keys.clear();
        self.held_mouse_buttons.clear();
        self.held_gamepad_buttons.clear();
        self.gamepad_axes.clear();
    }
}
