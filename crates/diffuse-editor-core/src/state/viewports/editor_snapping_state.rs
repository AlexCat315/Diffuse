//! `Editor/Sources/EditorCore/State/Viewports/EditorSnappingState.swift`.

use serde::{Deserialize, Serialize};

use crate::state::editor_state::EditorState;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EditorSnappingState {
    pub translate_snap_enabled: bool,
    pub rotate_snap_enabled: bool,
    pub scale_snap_enabled: bool,
    pub translate_snap_step: f32,
    pub rotate_snap_step_degrees: f32,
    pub scale_snap_step: f32,
}

impl EditorSnappingState {
    /// Swift's `init(_ configure:)` without a configuration closure.
    pub fn new() -> Self {
        EditorSnappingState::default()
    }

    /// Swift's `init(_ configure:)` with the closure applied.
    pub fn with_configure(configure: impl FnOnce(&mut EditorSnappingState)) -> Self {
        let mut state = EditorSnappingState::default();
        configure(&mut state);
        state
    }

    pub fn normalize(&mut self) {
        self.translate_snap_step =
            EditorState::sanitized_translate_snap_step(self.translate_snap_step);
        self.rotate_snap_step_degrees =
            EditorState::sanitized_rotate_snap_step(self.rotate_snap_step_degrees);
        self.scale_snap_step = EditorState::sanitized_scale_snap_step(self.scale_snap_step);
    }
}

impl Default for EditorSnappingState {
    fn default() -> Self {
        EditorSnappingState {
            translate_snap_enabled: false,
            rotate_snap_enabled: false,
            scale_snap_enabled: false,
            translate_snap_step: 0.5,
            rotate_snap_step_degrees: 5.0,
            scale_snap_step: 0.05,
        }
    }
}
