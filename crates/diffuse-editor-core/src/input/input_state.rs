//! `Editor/Sources/EditorCore/Input/InputState.swift`.

use std::collections::{BTreeSet, HashSet};

use diffuse_kernel::input_event::{InputEvent, KeyModifiers, MouseButton};

/// The editor's pointer/keyboard state, folded from one frame of engine events.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct InputState {
    pub pressed_keys: BTreeSet<u32>,
    pub mouse_x: f32,
    pub mouse_y: f32,
    pub mouse_delta_x: f32,
    pub mouse_delta_y: f32,
    pub pressed_mouse_buttons: HashSet<MouseButton>,
    pub modifiers: KeyModifiers,
    pub scroll_delta_x: f32,
    pub scroll_delta_y: f32,
}

impl InputState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn process(&mut self, events: &[InputEvent]) {
        self.mouse_delta_x = 0.0;
        self.mouse_delta_y = 0.0;
        self.scroll_delta_x = 0.0;
        self.scroll_delta_y = 0.0;

        for event in events {
            match event {
                InputEvent::KeyDown(event) => {
                    self.pressed_keys.insert(event.scancode);
                    self.modifiers = event.modifiers;
                }
                InputEvent::KeyUp(event) => {
                    self.pressed_keys.remove(&event.scancode);
                    self.modifiers = event.modifiers;
                }
                InputEvent::MouseMotion(event) => {
                    self.mouse_x = event.x;
                    self.mouse_y = event.y;
                    self.mouse_delta_x += event.delta_x;
                    self.mouse_delta_y += event.delta_y;
                }
                InputEvent::MouseButtonDown(event) => {
                    self.pressed_mouse_buttons.insert(event.button);
                    self.mouse_x = event.x;
                    self.mouse_y = event.y;
                    self.modifiers = event.modifiers;
                }
                InputEvent::MouseButtonUp(event) => {
                    self.pressed_mouse_buttons.remove(&event.button);
                    self.mouse_x = event.x;
                    self.mouse_y = event.y;
                    self.modifiers = event.modifiers;
                }
                InputEvent::MouseWheel(event) => {
                    let (delta_x, delta_y) = event.displacement(10.0, 30.0, 30.0);
                    self.scroll_delta_x += delta_x / 10.0;
                    self.scroll_delta_y += delta_y / 10.0;
                }
                InputEvent::WindowFocusLost | InputEvent::WindowMinimized => {
                    self.pressed_keys.clear();
                    self.pressed_mouse_buttons.clear();
                    self.modifiers = KeyModifiers::default();
                    self.mouse_delta_x = 0.0;
                    self.mouse_delta_y = 0.0;
                    self.scroll_delta_x = 0.0;
                    self.scroll_delta_y = 0.0;
                }
                _ => {}
            }
        }
    }

    pub fn is_key_pressed(&self, scancode: u32) -> bool {
        self.pressed_keys.contains(&scancode)
    }

    pub fn is_mouse_button_pressed(&self, button: MouseButton) -> bool {
        self.pressed_mouse_buttons.contains(&button)
    }
}
