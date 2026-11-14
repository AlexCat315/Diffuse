//! `Editor/Sources/EditorCore/Application/Persistence/Playback.swift`.

use cove_platform::InputEvent;
use diffuse_render::core::render_settings::{Backdrop, DebugViewMode, RenderSettings};
use diffuse_scene::physics::backend::physics_backend_kind::PhysicsBackendKind;
use diffuse_scene::physics::physics_types::PhysicsSimulationMode;

use crate::application::editor_application::EditorApplication;
use crate::editing::viewport::editor_viewport_input_controller::EditorViewportInputController;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::PlaybackState;
use crate::state::workspace::editor_workbench_state::EditorViewportMode;

use super::scene_persistence::{EditorScenePersistence, PlaySnapshot};

impl EditorScenePersistence {
    pub(crate) fn apply_playback_state(&self, next: PlaybackState) -> bool {
        if !self.store.playback_state().can_transition(next) {
            return false;
        }
        let scripts = &self.scene.script_runtime;
        match next {
            PlaybackState::Playing => {
                self.store
                    .dispatch(EditorAction::SetViewportMode(EditorViewportMode::Game));
                if self.play_snapshot.borrow().is_none() {
                    scripts.reset();
                    self.play_snapshot.replace(Some(PlaySnapshot {
                        scene: self.scene.scene(),
                        authored_revision: self.store.scene_revision(),
                    }));
                    self.persist_physics_play_snapshot();
                }
                self.scene.set_authoring_enabled(false);
                self.scene.set_editor_viewport_camera_enabled(false);
                scripts.set_gameplay_execution_enabled(true);
                self.set_simulation_mode(PhysicsSimulationMode::Play, false);
            }
            PlaybackState::Paused => {
                self.scene.set_authoring_enabled(false);
                self.scene.set_editor_viewport_camera_enabled(false);
                scripts.set_gameplay_execution_enabled(false);
                self.set_simulation_mode(PhysicsSimulationMode::Off, false);
            }
            PlaybackState::Stopped => {
                self.store
                    .dispatch(EditorAction::SetViewportMode(EditorViewportMode::Scene));
                scripts.set_gameplay_execution_enabled(false);
                self.scene.with_scene_mut(|scene| scripts.stop(scene));
                self.scene.audio_engine.reset_playback_state();
                let revision = match self.play_snapshot.take() {
                    Some(snapshot) => {
                        self.scene.set_scene(snapshot.scene);
                        snapshot.authored_revision
                    }
                    None => {
                        if let Some(scene) = self.load_persisted_physics_play_snapshot() {
                            self.scene.set_scene(scene);
                        } else {
                            self.set_simulation_mode(PhysicsSimulationMode::Off, true);
                        }
                        self.scene.revision()
                    }
                };
                self.delete_persisted_physics_play_snapshot();
                self.scene.set_authoring_enabled(true);
                self.scene.set_editor_viewport_camera_enabled(true);
                self.scene.notify_revision_changed(false, None);
                self.store
                    .dispatch(EditorAction::SetSceneRevision(revision));
            }
        }
        self.store.dispatch(EditorAction::SetPlaybackState(next));
        let message = match next {
            PlaybackState::Playing => "Physics simulation started",
            PlaybackState::Paused => "Physics simulation paused",
            PlaybackState::Stopped => "Physics simulation stopped",
        };
        self.store.dispatch(EditorAction::console_message(message));
        true
    }

    fn set_simulation_mode(&self, mode: PhysicsSimulationMode, disable_backend: bool) {
        self.scene.with_scene_mut(|scene| {
            let mut settings = scene.physics_settings();
            settings.simulation_mode = mode;
            if disable_backend {
                settings.backend_kind = PhysicsBackendKind::None;
            }
            scene.set_physics_settings(settings);
        });
    }
}

impl EditorApplication {
    pub fn apply_playback_state(&self, next: PlaybackState) {
        if !self.store.playback_state().can_transition(next) {
            return;
        }
        EditorViewportInputController::shared().reset();
        self.pending_viewport_events
            .borrow_mut()
            .push(InputEvent::WindowFocusLost);
        if let Some(mesh) = self.mesh_editing.get()
            && mesh.is_editing()
        {
            mesh.leave();
        }
        self.scene_persistence().apply_playback_state(next);
        self.queue_viewport_render_settings();
        self.request_display_refresh();
    }

    pub(crate) fn queue_viewport_render_settings(&self) {
        let in_scene = self.store.viewport_mode() == EditorViewportMode::Scene;
        let settings = RenderSettings::configured(|settings| {
            settings.shading.debug_view_mode = DebugViewMode::from_raw_value(
                self.store.viewport_shading_mode().debug_view_index(),
            )
            .unwrap_or_default();
            settings.shadows.enabled = self.store.viewport_shadows_enabled();
            settings.viewport.offscreen = true;
            settings.viewport.backdrop = if in_scene {
                Backdrop::Studio
            } else {
                Backdrop::Sky
            };
            settings.viewport.grid_enabled = in_scene && self.store.viewport_grid_enabled();
            settings.viewport.grid_spacing = if self.store.translate_snap_enabled() {
                self.store.translate_snap_step()
            } else {
                1.0
            };
        });
        let generation = self.render_settings_generation.borrow().wrapping_add(1);
        self.render_settings_generation.replace(generation);
        self.last_queued_render_settings.replace(settings);
        self.engine.queue_render_settings(settings);
    }
}
