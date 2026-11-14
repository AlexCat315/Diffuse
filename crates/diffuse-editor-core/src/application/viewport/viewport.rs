//! Desktop viewport input and presentation from `Application/Viewport/Viewport.swift`.

use cove_platform::{InputEvent, MouseButton};
use diffuse_render::{RenderDrawableSize, surface::viewport_surface::ViewportSurfaceState};

use crate::application::editor_application::EditorApplication;
use crate::assets::asset_catalog::EditorViewportDropTarget;
use crate::editing::viewport::editor_viewport_input_controller::{ActiveInteraction, CameraDrag, EditorViewportInputController};
use crate::editing::viewport::editor_viewport_resolution::EditorViewportResolution;
use crate::state::editor_reducer::EditorAction;
use crate::state::workspace::editor_workbench_state::EditorViewportMode;

impl EditorApplication {
    pub fn viewport_surface(&self) -> ViewportSurfaceState {
        self.store.viewport_surface_revision();
        self.last_viewport_surface_state.borrow().clone()
    }

    pub fn set_viewport_drawable_size(&self, size: RenderDrawableSize) {
        if *self.viewport_drawable_size.borrow() != size {
            self.viewport_drawable_size.replace(size);
            self.request_display_refresh();
        }
    }

    pub fn set_viewport_grid_enabled(&self, enabled: bool) {
        self.store.dispatch(EditorAction::SetViewportGridEnabled(enabled));
        self.queue_viewport_render_settings();
        self.request_display_refresh();
    }

    pub(super) fn effective_viewport_drawable_size(&self) -> RenderDrawableSize {
        let drawable = *self.viewport_drawable_size.borrow();
        if self.store.viewport_mode() == EditorViewportMode::Game {
            return self.store.game_preview_resolution().size().unwrap_or(drawable);
        }
        EditorViewportResolution::effective_size(drawable, self.store.viewport_render_scale_percent(),
            self.store.viewport_interaction_downscale_enabled() && self.viewport_interacting())
    }

    pub(super) fn viewport_interacting(&self) -> bool {
        EditorViewportInputController::shared().is_continuous_scene_interaction_active()
    }

    pub(super) fn drive_continuous_viewport_camera(&self, elapsed: f64) {
        let input = EditorViewportInputController::shared();
        if input.has_freelook_movement_input() && self.store.viewport_mode() == EditorViewportMode::Scene {
            self.scene.freelook_camera(0.0, 0.0, &input.pressed_scancodes(), input.modifiers(), elapsed as f32);
        }
    }

    pub fn handle_viewport_input(&self, event: InputEvent) {
        self.pending_viewport_events.borrow_mut().push(event.clone());
        self.request_display_refresh();
        if self.store.viewport_mode() != EditorViewportMode::Scene {
            return;
        }
        let input = EditorViewportInputController::shared();
        let Some(frame) = EditorViewportDropTarget::frame() else { return; };
        match event {
            InputEvent::MouseButtonDown(event) => {
                let drag = match event.button {
                    MouseButton::Middle if event.modifiers.has_shift() => CameraDrag::Pan,
                    MouseButton::Middle => CameraDrag::Orbit,
                    MouseButton::Right if event.modifiers.has_alt() => CameraDrag::Dolly,
                    MouseButton::Right => CameraDrag::Freelook,
                    MouseButton::Left if event.modifiers.has_alt() => CameraDrag::Orbit,
                    MouseButton::Left => {
                        input.begin(ActiveInteraction::PendingClick { button: event.button }, (event.x, event.y), event.modifiers);
                        return;
                    }
                    _ => return,
                };
                input.begin(ActiveInteraction::Camera { drag, button: event.button }, (event.x, event.y), event.modifiers);
            }
            InputEvent::MouseButtonUp(event) => {
                match input.active_interaction() {
                    Some(ActiveInteraction::PendingClick { button }) if button == event.button => {
                        if frame.contains(event.x, event.y) && input.left_down_at().is_none_or(|(x, y)| (event.x - x).hypot(event.y - y) <= 6.0) {
                            let id = self.scene.pick_entity(event.x, event.y, frame);
                            if let Some(id) = id.filter(|_| event.modifiers.has_shift() || event.modifiers.has_ctrl() || event.modifiers.has_gui()) {
                                let mut selection = self.store.selected_entity_ids();
                                if !selection.insert(id) && !event.modifiers.has_shift() { selection.remove(&id); }
                                self.store.dispatch(EditorAction::SetSelectedEntities(selection));
                            } else {
                                self.store.dispatch(EditorAction::SetSelectedEntity(id));
                            }
                        }
                    }
                    Some(ActiveInteraction::Camera { button, .. }) if button == event.button => {}
                    _ => return,
                }
                input.end_pointer_session_default();
            }
            InputEvent::MouseMotion(event) => if let Some(ActiveInteraction::Camera { drag, .. }) = input.active_interaction() {
                match drag {
                    CameraDrag::Orbit => self.scene.orbit_camera(event.delta_x, event.delta_y, frame),
                    CameraDrag::Pan => self.scene.pan_camera(event.delta_x, event.delta_y, frame),
                    CameraDrag::Dolly => self.scene.dolly_camera(event.delta_y),
                    CameraDrag::Freelook => self.scene.freelook_camera(event.delta_x, event.delta_y, &input.pressed_scancodes(), input.modifiers(), 0.0),
                }
            },
            InputEvent::MouseWheel(event) => {
                let (_, y) = event.displacement(30.0, frame.width, frame.height);
                self.scene.dolly_camera(-y);
            }
            InputEvent::KeyDown(event) => {
                input.set_pressed_scancode(event.scancode, true);
                input.set_modifiers(event.modifiers);
            }
            InputEvent::KeyUp(event) => {
                input.set_pressed_scancode(event.scancode, false);
                input.set_modifiers(event.modifiers);
            }
            InputEvent::WindowFocusLost => input.reset(),
            _ => {}
        }
    }

    pub(super) fn handle_platform_event(&self, event: &InputEvent) {
        let action = match event {
            InputEvent::WindowFocusGained => EditorAction::SetWindowFocused(true),
            InputEvent::WindowFocusLost => EditorAction::SetWindowFocused(false),
            InputEvent::WindowMinimized => EditorAction::SetWindowMinimized(true),
            InputEvent::WindowRestored => {
                self.store.dispatch(EditorAction::SetWindowMinimized(false));
                EditorAction::SetWindowOccluded(false)
            }
            InputEvent::WindowOccluded => EditorAction::SetWindowOccluded(true),
            InputEvent::WindowExposed => EditorAction::SetWindowOccluded(false),
            _ => return,
        };
        if matches!(event, InputEvent::WindowFocusLost | InputEvent::WindowMinimized | InputEvent::WindowOccluded) {
            EditorViewportInputController::shared().reset();
            self.scene.end_interactive_edit_history_group();
            self.pending_viewport_events.borrow_mut().push(InputEvent::WindowFocusLost);
        }
        self.store.dispatch(action);
    }
}
