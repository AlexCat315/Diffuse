//! `Editor/Sources/EditorCore/State/Viewports/EditorViewportState.swift`.

use serde::{Deserialize, Serialize};

use crate::state::editor_state::{
    EditorGizmoMode, EditorGizmoSpace, EditorPhysicsDebugOverlayOptions,
    EditorPhysicsDebugOverlayScope, EditorState, EditorViewportShadingMode,
};
use crate::state::workspace::editor_workbench_state::{
    EditorGamePreviewResolution, EditorViewportMode,
};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EditorViewportState {
    pub surface_revision: u64,
    #[serde(skip)]
    pub camera_revision: u64,
    pub gizmo_mode: EditorGizmoMode,
    pub gizmo_space: EditorGizmoSpace,
    pub shading_mode: EditorViewportShadingMode,
    pub grid_enabled: bool,
    pub render_scale_percent: i64,
    pub interaction_downscale_enabled: bool,
    pub realtime_enabled: bool,
    pub physics_debug_overlay_options: EditorPhysicsDebugOverlayOptions,
    pub physics_debug_overlay_scope: EditorPhysicsDebugOverlayScope,
    #[serde(skip)]
    pub mode: EditorViewportMode,
    #[serde(skip)]
    pub game_preview_resolution: EditorGamePreviewResolution,
    #[serde(skip)]
    pub game_preview_hud_enabled: bool,
    #[serde(skip)]
    pub game_preview_focused: bool,
}

impl EditorViewportState {
    /// Swift's `init(_ configure:)` without a configuration closure.
    pub fn new() -> Self {
        EditorViewportState::default()
    }

    /// Swift's `init(_ configure:)` with the closure applied.
    pub fn with_configure(configure: impl FnOnce(&mut EditorViewportState)) -> Self {
        let mut state = EditorViewportState::default();
        configure(&mut state);
        state
    }

    pub fn normalize(&mut self) {
        self.render_scale_percent =
            EditorState::sanitized_render_scale_percent(self.render_scale_percent);
        self.physics_debug_overlay_options = self
            .physics_debug_overlay_options
            .intersection(EditorPhysicsDebugOverlayOptions::all());
    }
}

impl Default for EditorViewportState {
    fn default() -> Self {
        EditorViewportState {
            surface_revision: 0,
            camera_revision: 0,
            gizmo_mode: EditorGizmoMode::Translate,
            gizmo_space: EditorGizmoSpace::Local,
            shading_mode: EditorViewportShadingMode::Lit,
            grid_enabled: true,
            render_scale_percent: 100,
            interaction_downscale_enabled: false,
            realtime_enabled: false,
            physics_debug_overlay_options: EditorPhysicsDebugOverlayOptions::new(0),
            physics_debug_overlay_scope: EditorPhysicsDebugOverlayScope::Selected,
            mode: EditorViewportMode::Scene,
            game_preview_resolution: EditorGamePreviewResolution::Fit,
            game_preview_hud_enabled: true,
            game_preview_focused: false,
        }
    }
}
