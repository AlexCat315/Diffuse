//! Translation of
//! Editor/Sources/EditorCore/Editing/Viewport/EditorViewportSnapSettings.swift.
//!
//! Per-project editor preferences, stored separately from authored scene data.

use serde::{Deserialize, Serialize};

use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::EditorState;
use crate::state::editor_store::EditorStore;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorViewportSnapSettings {
    pub translate_enabled: bool,
    pub rotate_enabled: bool,
    pub scale_enabled: bool,
    pub translate_step: f32,
    pub rotate_step_degrees: f32,
    pub scale_step: f32,
}

impl EditorViewportSnapSettings {
    pub fn new(state: &EditorState) -> Self {
        EditorViewportSnapSettings {
            translate_enabled: state.snapping.translate_snap_enabled,
            rotate_enabled: state.snapping.rotate_snap_enabled,
            scale_enabled: state.snapping.scale_snap_enabled,
            translate_step: EditorState::sanitized_translate_snap_step(
                state.snapping.translate_snap_step,
            ),
            rotate_step_degrees: EditorState::sanitized_rotate_snap_step(
                state.snapping.rotate_snap_step_degrees,
            ),
            scale_step: EditorState::sanitized_scale_snap_step(state.snapping.scale_snap_step),
        }
    }

    pub fn restore(&self, store: &EditorStore) {
        store.dispatch(EditorAction::SetTranslateSnapEnabled(
            self.translate_enabled,
        ));
        store.dispatch(EditorAction::SetRotateSnapEnabled(self.rotate_enabled));
        store.dispatch(EditorAction::SetScaleSnapEnabled(self.scale_enabled));
        store.dispatch(EditorAction::SetTranslateSnapStep(self.translate_step));
        store.dispatch(EditorAction::SetRotateSnapStepDegrees(
            self.rotate_step_degrees,
        ));
        store.dispatch(EditorAction::SetScaleSnapStep(self.scale_step));
    }
}
