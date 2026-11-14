//! `Editor/Sources/EditorCore/Application/Editing/UndoRedo.swift`.

use crate::application::editor_application::EditorApplication;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{EditorConsoleSeverity, PlaybackState};

impl EditorApplication {
    pub fn can_undo(&self) -> bool { self.scene.can_undo_edit() }
    pub fn can_redo(&self) -> bool { self.scene.can_redo_edit() }

    pub fn undo(&self) { self.navigate_scene_history(false); }
    pub fn redo(&self) { self.navigate_scene_history(true); }

    fn navigate_scene_history(&self, redo: bool) {
        if self.mesh_editing.get().is_some_and(|mesh| mesh.cancel_interactive_edit()) {
            return;
        }
        if self.store.playback_state() != PlaybackState::Stopped {
            self.report_scene_authoring_unavailable(if redo {
                "Stop simulation before redoing scene edits."
            } else {
                "Stop simulation before undoing scene edits."
            });
            return;
        }
        let (applied, status, message) = if redo {
            (self.scene.redo_edit(), "Redone", "Redo applied")
        } else {
            (self.scene.undo_edit(), "Undone", "Undo applied")
        };
        if applied {
            if self.scene.entity_summary(self.store.selected_entity_id()).is_none() {
                self.store.dispatch(EditorAction::SetSelectedEntity(self.scene.roots().first().map(|root| root.id)));
            }
            self.request_display_refresh();
            self.store.dispatch(EditorAction::SetAIStatusMessage(Some(status.into())));
            self.store.dispatch(EditorAction::console_message(message));
        }
    }

    pub fn report_scene_authoring_unavailable(&self, message: &str) {
        self.store.dispatch(EditorAction::SetAIStatusMessage(Some(message.into())));
        self.store.dispatch(EditorAction::AppendConsoleMessage {
            message: message.into(), severity: EditorConsoleSeverity::Warning,
            detail: None, target: None, next_step: None,
        });
    }
}
