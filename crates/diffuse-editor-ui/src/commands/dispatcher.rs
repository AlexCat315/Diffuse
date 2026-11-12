//! `Editor/Sources/EditorUI/Commands/Dispatcher.swift` (availability half;
//! command execution lands with the workspace controller).

use cove_ui_compose::scene_core::{FocusChainHolder, TextEditCommand};

use crate::commands::command::EditorCommand;

pub struct EditorCommandDispatcher;

impl EditorCommandDispatcher {
    /// Undo/redo follow a focused text field when it owns that operation; a
    /// modal scope blocks every other scene command.
    pub fn is_enabled(command: &EditorCommand, scene_command_enabled: bool) -> bool {
        let focus = FocusChainHolder::current();
        if let Some(focus) = focus.as_ref() {
            let text_command = match command {
                EditorCommand::Undo => Some(TextEditCommand::Undo),
                EditorCommand::Redo => Some(TextEditCommand::Redo),
                _ => None,
            };
            if let Some(text_command) = text_command
                && let Some(available) = focus.text_edit_availability(text_command)
            {
                return available;
            }
            if focus.modal_root().is_some() {
                return false;
            }
        }
        scene_command_enabled
    }
}
