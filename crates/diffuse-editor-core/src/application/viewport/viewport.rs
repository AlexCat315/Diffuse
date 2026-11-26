//! Desktop viewport input and presentation from `Application/Viewport/Viewport.swift`.

use std::sync::Arc;

use cove_platform::{InputEvent, MouseButton};
use diffuse_render::RenderDrawableSize;
use diffuse_render::core::render_settings::{
    Backdrop, DebugViewMode, RenderSettings, RenderShadowSettings,
};
use diffuse_render::surface::viewport_surface::ViewportSurfaceState;

use crate::application::editor_application::EditorApplication;
use crate::assets::asset_catalog::EditorViewportDropTarget;
use crate::editing::viewport::editor_viewport_input_controller::{
    ActiveInteraction, CameraDrag, EditorViewportInputController,
};
use crate::editing::viewport::editor_viewport_resolution::EditorViewportResolution;
use crate::editing::viewport::editor_viewport_snap_settings::EditorViewportSnapSettings;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{
    EditorConsoleSeverity, EditorState, EditorViewportShadingMode, PlaybackState,
};
use crate::state::workspace::editor_workbench_state::EditorGamePreviewResolution;
use crate::state::workspace::editor_workbench_state::{EditorIssueTarget, EditorViewportMode};

/// Thin wrapper so the shutdown path has one place to read the preparation
/// subscription.
impl EditorApplication {
    pub fn viewport_surface(&self) -> ViewportSurfaceState {
        self.store.viewport_surface_revision();
        self.last_viewport_surface_state.borrow().clone()
    }

    /// `setViewportMode(_:)` — leaves freelook, stops playback and re-queues
    /// render settings for the new mode.
    pub fn set_viewport_mode(&self, mode: EditorViewportMode) {
        if mode == self.store.viewport_mode() {
            return;
        }
        EditorViewportInputController::shared().reset();
        if mode == EditorViewportMode::Scene && self.store.playback_state() != PlaybackState::Stopped
        {
            self.apply_playback_state(PlaybackState::Stopped);
        }
        self.store.dispatch(EditorAction::SetViewportMode(mode));
        self.scene
            .set_editor_viewport_camera_enabled(mode == EditorViewportMode::Scene);
        self.enqueue_viewport_input(InputEvent::WindowFocusLost);
        self.queue_tracked_render_settings(self.make_viewport_render_settings(
            self.store.viewport_shadows_enabled(),
            self.store.viewport_shading_mode(),
        ));
        self.request_display_refresh();
    }

    pub fn set_game_preview_resolution(&self, resolution: EditorGamePreviewResolution) {
        self.store
            .dispatch(EditorAction::SetGamePreviewResolution(resolution));
        self.request_display_refresh();
    }

    pub fn set_game_preview_hud_enabled(&self, enabled: bool) {
        self.store
            .dispatch(EditorAction::SetGamePreviewHUDEnabled(enabled));
        self.bump_render_settings_generation();
        self.request_display_refresh();
    }

    /// `enqueueViewportInput(_:)` — queues an event for the engine tick and
    /// wakes the display.
    pub fn enqueue_viewport_input(&self, event: InputEvent) {
        self.pending_viewport_events.borrow_mut().push(event);
        self.request_display_refresh();
    }

    pub fn set_viewport_drawable_size(&self, size: RenderDrawableSize) {
        if *self.viewport_drawable_size.borrow() == size {
            return;
        }
        self.viewport_drawable_size.replace(size);
        self.request_display_refresh();
    }

    pub fn set_viewport_render_scale_percent(&self, percent: i64) {
        let sanitized = EditorState::sanitized_render_scale_percent(percent);
        if self.store.viewport_render_scale_percent() == sanitized {
            return;
        }
        self.store
            .dispatch(EditorAction::SetViewportRenderScalePercent(sanitized));
        self.log_console(
            "Viewport render scale",
            EditorConsoleSeverity::Info,
            Some(format!("{sanitized}%")),
            Option::<EditorIssueTarget>::None,
            None,
        );
    }

    pub fn set_viewport_interaction_downscale_enabled(&self, enabled: bool) {
        if self.store.viewport_interaction_downscale_enabled() == enabled {
            return;
        }
        self.store
            .dispatch(EditorAction::SetViewportInteractionDownscale(enabled));
        self.log_console(
            if enabled {
                "Viewport interaction downscale enabled"
            } else {
                "Viewport interaction downscale disabled"
            },
            EditorConsoleSeverity::Info,
            None,
            Option::<EditorIssueTarget>::None,
            None,
        );
    }

    pub fn set_viewport_realtime_enabled(&self, enabled: bool) {
        if self.store.viewport_realtime_enabled() == enabled {
            return;
        }
        self.store.dispatch(EditorAction::SetViewportRealtime(enabled));
        self.log_console(
            if enabled {
                "Viewport realtime rendering enabled"
            } else {
                "Viewport renders on demand"
            },
            EditorConsoleSeverity::Info,
            None,
            Option::<EditorIssueTarget>::None,
            None,
        );
        self.request_display_refresh();
    }

    /// `monotonicNow()` — seconds since the process's monotonic anchor.
    pub fn monotonic_now(&self) -> f64 {
        use std::sync::OnceLock;
        use std::time::Instant;
        static ANCHOR: OnceLock<Instant> = OnceLock::new();
        ANCHOR.get_or_init(Instant::now).elapsed().as_secs_f64()
    }

    /// `setViewportRenderCompletionHandler(_:)`.
    pub fn set_viewport_render_completion_handler(
        &self,
        handler: Option<Arc<dyn Fn(ViewportSurfaceState) + Send + Sync>>,
    ) {
        self.engine
            .set_render_completion_handler(Some(Arc::new(move |completion| {
                if let Some(handler) = handler.as_ref() {
                    handler(completion.viewport_surface_state.clone());
                }
            })));
    }

    pub fn set_viewport_grid_enabled(&self, enabled: bool) {
        if self.store.viewport_grid_enabled() == enabled {
            return;
        }
        self.store
            .dispatch(EditorAction::SetViewportGridEnabled(enabled));
        let mut settings = *self.last_queued_render_settings.borrow();
        settings.viewport.grid_enabled = enabled;
        self.queue_tracked_render_settings(settings);
        self.request_display_refresh();
    }

    /// `queueViewportRenderSettings(_:)` — grid state comes from the store, not
    /// from the caller's copy.
    pub fn queue_viewport_render_settings_with(&self, mut settings: RenderSettings) {
        settings.viewport.grid_enabled = self.store.viewport_grid_enabled();
        settings.viewport.grid_spacing = self.viewport_grid_spacing();
        self.queue_tracked_render_settings(settings);
    }

    /// Single funnel for render-settings changes: bumps the generation the
    /// viewport render gate folds into its dirty signature.
    pub(crate) fn queue_tracked_render_settings(&self, settings: RenderSettings) {
        self.bump_render_settings_generation();
        self.last_queued_render_settings.replace(settings.clone());
        self.engine.queue_render_settings(settings);
    }

    fn bump_render_settings_generation(&self) {
        let next = self.render_settings_generation.borrow().wrapping_add(1);
        self.render_settings_generation.replace(next);
    }

    pub fn set_viewport_shadows_enabled(&self, enabled: bool) {
        if self.store.viewport_shadows_enabled() != enabled {
            self.store
                .dispatch(EditorAction::SetViewportShadowsEnabled(enabled));
        }
        self.queue_tracked_render_settings(self.make_viewport_render_settings(
            enabled,
            self.store.viewport_shading_mode(),
        ));
        self.log_console(
            if enabled {
                "Viewport shadows enabled"
            } else {
                "Viewport shadows disabled"
            },
            EditorConsoleSeverity::Info,
            None,
            Option::<EditorIssueTarget>::None,
            None,
        );
    }

    pub(crate) fn viewport_grid_spacing(&self) -> f32 {
        if self.store.translate_snap_enabled() {
            self.store.translate_snap_step()
        } else {
            1.0
        }
    }

    /// `restoreAndObserveViewportSnapSettings()` — restores the per-project
    /// snapping preferences and writes them back on every change.
    pub(crate) fn restore_and_observe_viewport_snap_settings(self: &std::rc::Rc<Self>) {
        let url = std::path::Path::new(&self.project_directory)
            .join(".cove")
            .join("editor-snap-settings.json");
        if let Ok(data) = std::fs::read(&url)
            && let Ok(saved) = serde_json::from_slice::<EditorViewportSnapSettings>(&data)
        {
            saved.restore(&self.store);
        }
        let previous = std::rc::Rc::new(std::cell::RefCell::new(EditorViewportSnapSettings::new(
            &self.store.state(),
        )));
        let weak = std::rc::Rc::downgrade(self);
        let token = self.store.subscribe(std::rc::Rc::new(move |store| {
            let Some(app) = weak.upgrade() else {
                return;
            };
            let next = EditorViewportSnapSettings::new(&store.state());
            if *previous.borrow() == next {
                return;
            }
            previous.replace(next.clone());
            match serde_json::to_vec(&next) {
                Ok(encoded) => {
                    use cove_system::atomic_file::AtomicFile;
                    use cove_system::files::Access;
                    if let Err(error) = AtomicFile::write(&encoded, &url, Access::Inherit) {
                        app.log_console(
                            "Could not save viewport snap settings",
                            EditorConsoleSeverity::Warning,
                            Some(error.to_string()),
                            Option::<EditorIssueTarget>::None,
                            None,
                        );
                    }
                }
                Err(error) => {
                    app.log_console(
                        "Could not save viewport snap settings",
                        EditorConsoleSeverity::Warning,
                        Some(error.to_string()),
                        Option::<EditorIssueTarget>::None,
                        None,
                    );
                }
            }
            let last = *app.last_queued_render_settings.borrow();
            let mut settings = last.clone();
            settings.viewport.grid_spacing = app.viewport_grid_spacing();
            if settings != last {
                app.queue_tracked_render_settings(settings);
            }
            app.request_display_refresh();
        }));
        self.subscriptions.set_settings(Some(token));
    }

    /// `setViewportShadingMode(_:)` — re-queues render settings so the mesh
    /// shader updates its G-buffer visualization.
    pub fn set_viewport_shading_mode(&self, mode: EditorViewportShadingMode) {
        if self.store.viewport_shading_mode() != mode {
            self.store.dispatch(EditorAction::SetViewportShadingMode(mode));
        }
        self.queue_tracked_render_settings(self.make_viewport_render_settings(
            self.store.viewport_shadows_enabled(),
            mode,
        ));
    }

    /// `makeViewportRenderSettings(shadowsEnabled:shadingMode:)`.
    pub(crate) fn make_viewport_render_settings(
        &self,
        shadows_enabled: bool,
        shading_mode: EditorViewportShadingMode,
    ) -> RenderSettings {
        let mut settings = RenderSettings::new();
        settings.shading.debug_view_mode = match shading_mode {
            EditorViewportShadingMode::Lit | EditorViewportShadingMode::Wireframe => {
                DebugViewMode::Shaded
            }
            EditorViewportShadingMode::Unlit => DebugViewMode::Unlit,
            EditorViewportShadingMode::BaseColor => DebugViewMode::BaseColor,
            EditorViewportShadingMode::Normal => DebugViewMode::WorldNormal,
            EditorViewportShadingMode::Roughness => DebugViewMode::Roughness,
            EditorViewportShadingMode::Metallic => DebugViewMode::Metallic,
        };
        let mut shadows = RenderShadowSettings::new_disabled();
        shadows.enabled = shadows_enabled;
        settings.shadows = shadows;
        settings.viewport.offscreen = true;
        settings.viewport.backdrop = if self.store.viewport_mode() == EditorViewportMode::Scene {
            Backdrop::Studio
        } else {
            Backdrop::Sky
        };
        settings.viewport.grid_enabled = self.store.viewport_grid_enabled()
            && self.store.viewport_mode() == EditorViewportMode::Scene;
        settings.viewport.grid_spacing = self.viewport_grid_spacing();
        settings
    }

    /// `currentSelectedEntityTranslation()`.
    pub fn current_selected_entity_translation(
        &self,
    ) -> Option<diffuse_math::simd::simd_compat::Float3> {
        let entity = self.entity_id(self.store.selected_entity_id())?;
        self.scene
            .scene()
            .local_transform(entity)
            .map(|transform| transform.translation())
    }

    pub(crate) fn effective_viewport_drawable_size(&self) -> RenderDrawableSize {
        let drawable = *self.viewport_drawable_size.borrow();
        if self.store.viewport_mode() == EditorViewportMode::Game {
            return self
                .store
                .game_preview_resolution()
                .size()
                .unwrap_or(drawable);
        }
        EditorViewportResolution::effective_size(
            drawable,
            self.store.viewport_render_scale_percent(),
            self.store.viewport_interaction_downscale_enabled() && self.viewport_interacting(),
        )
    }

    pub(crate) fn viewport_interacting(&self) -> bool {
        EditorViewportInputController::shared().is_continuous_scene_interaction_active()
    }

    pub(crate) fn drive_continuous_viewport_camera(&self, elapsed: f64) {
        let input = EditorViewportInputController::shared();
        if input.has_freelook_movement_input()
            && self.store.viewport_mode() == EditorViewportMode::Scene
        {
            self.scene.freelook_camera(
                0.0,
                0.0,
                &input.pressed_scancodes(),
                input.modifiers(),
                elapsed.max(0.0) as f32,
            );
        }
    }

    pub fn handle_viewport_input(&self, event: InputEvent) {
        self.pending_viewport_events.borrow_mut().push(event.clone());
        self.request_display_refresh();
        if self.store.viewport_mode() != EditorViewportMode::Scene {
            return;
        }
        let input = EditorViewportInputController::shared();
        let Some(frame) = EditorViewportDropTarget::frame() else {
            return;
        };
        match event {
            InputEvent::MouseButtonDown(event) => {
                let drag = match event.button {
                    MouseButton::Middle if event.modifiers.has_shift() => CameraDrag::Pan,
                    MouseButton::Middle => CameraDrag::Orbit,
                    MouseButton::Right if event.modifiers.has_alt() => CameraDrag::Dolly,
                    MouseButton::Right => CameraDrag::Freelook,
                    MouseButton::Left if event.modifiers.has_alt() => CameraDrag::Orbit,
                    MouseButton::Left => {
                        input.begin(
                            ActiveInteraction::PendingClick {
                                button: event.button,
                            },
                            (event.x, event.y),
                            event.modifiers,
                        );
                        return;
                    }
                    _ => return,
                };
                input.begin(
                    ActiveInteraction::Camera {
                        drag,
                        button: event.button,
                    },
                    (event.x, event.y),
                    event.modifiers,
                );
            }
            InputEvent::MouseButtonUp(event) => {
                match input.active_interaction() {
                    Some(ActiveInteraction::PendingClick { button }) if button == event.button => {
                        if frame.contains(event.x, event.y)
                            && input
                                .left_down_at()
                                .is_none_or(|(x, y)| (event.x - x).hypot(event.y - y) <= 6.0)
                        {
                            let id = self.scene.pick_entity(event.x, event.y, frame);
                            if let Some(id) = id.filter(|_| {
                                event.modifiers.has_shift()
                                    || event.modifiers.has_ctrl()
                                    || event.modifiers.has_gui()
                            }) {
                                let mut selection = self.store.selected_entity_ids();
                                if !selection.insert(id) && !event.modifiers.has_shift() {
                                    selection.remove(&id);
                                }
                                self.store
                                    .dispatch(EditorAction::SetSelectedEntities(selection));
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
            InputEvent::MouseMotion(event) => {
                if let Some(ActiveInteraction::Camera { drag, .. }) = input.active_interaction() {
                    match drag {
                        CameraDrag::Orbit => {
                            self.scene.orbit_camera(event.delta_x, event.delta_y, frame)
                        }
                        CameraDrag::Pan => {
                            self.scene.pan_camera(event.delta_x, event.delta_y, frame)
                        }
                        CameraDrag::Dolly => self.scene.dolly_camera(event.delta_y),
                        CameraDrag::Freelook => self.scene.freelook_camera(
                            event.delta_x,
                            event.delta_y,
                            &input.pressed_scancodes(),
                            input.modifiers(),
                            0.0,
                        ),
                    }
                }
            }
            InputEvent::MouseWheel(event) => {
                let (_, y) = event.displacement(30.0, frame.width, frame.height);
                self.scene.dolly_camera(-y);
            }
            InputEvent::KeyDown(event) => {
                let mut scancodes = input.pressed_scancodes();
                scancodes.insert(event.scancode);
                input.set_pressed_scancodes(scancodes);
                input.set_modifiers(event.modifiers);
            }
            InputEvent::KeyUp(event) => {
                let mut scancodes = input.pressed_scancodes();
                scancodes.remove(&event.scancode);
                input.set_pressed_scancodes(scancodes);
                input.set_modifiers(event.modifiers);
            }
            InputEvent::WindowFocusLost => input.reset(),
            _ => {}
        }
    }

    pub(crate) fn handle_platform_event(&self, event: &InputEvent) {
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
        if matches!(
            event,
            InputEvent::WindowFocusLost | InputEvent::WindowMinimized | InputEvent::WindowOccluded
        ) {
            EditorViewportInputController::shared().reset();
            self.scene.end_interactive_edit_history_group();
            self.pending_viewport_events
                .borrow_mut()
                .push(InputEvent::WindowFocusLost);
        }
        self.store.dispatch(action);
    }
}
