//! `Editor/Sources/EditorCore/State/Viewports/EditorShadowsState.swift`.

use serde::{Deserialize, Serialize};

use crate::state::editor_state::{EditorState, EditorViewportShadowDebugMode};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EditorShadowsState {
    pub enabled: bool,
    pub map_resolution: u32,
    pub max_directional_lights: i64,
    pub cascade_count: i64,
    pub cascade_split_lambda: f32,
    pub debug_mode: EditorViewportShadowDebugMode,
}

impl EditorShadowsState {
    /// Swift's `init(_ configure:)` without a configuration closure.
    pub fn new() -> Self {
        EditorShadowsState::default()
    }

    /// Swift's `init(_ configure:)` with the closure applied.
    pub fn with_configure(configure: impl FnOnce(&mut EditorShadowsState)) -> Self {
        let mut state = EditorShadowsState::default();
        configure(&mut state);
        state
    }

    pub fn normalize(&mut self) {
        self.map_resolution = EditorState::sanitized_shadow_map_resolution(self.map_resolution);
        self.max_directional_lights =
            EditorState::sanitized_max_shadowed_directional_lights(self.max_directional_lights);
        self.cascade_count = EditorState::sanitized_directional_cascade_count(self.cascade_count);
        self.cascade_split_lambda =
            EditorState::sanitized_directional_cascade_split_lambda(self.cascade_split_lambda);
    }
}

impl Default for EditorShadowsState {
    fn default() -> Self {
        EditorShadowsState {
            enabled: true,
            map_resolution: 1024,
            max_directional_lights: 1,
            cascade_count: 1,
            cascade_split_lambda: 0.55,
            debug_mode: EditorViewportShadowDebugMode::Off,
        }
    }
}
