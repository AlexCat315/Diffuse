//! `Editor/Sources/EditorUI/Root/Chrome/ShortcutHandler.swift`.
//!
//! Key chords that reach the window: everything on Windows and Linux, and on
//! macOS whatever the native menu bar did not already claim. Chords come from
//! the command catalog, so a menu label and its key can never disagree.

use cove_platform::KeyEvent;
use cove_ui_compose::Scancode;

use crate::commands::catalog::{EditorCommandCatalog, EditorCommandEntry};
use crate::commands::command::EditorCommand;
use crate::commands::dispatcher::EditorCommandDispatcher;

pub enum EditorShortcutHandler {}

impl EditorShortcutHandler {
    pub fn handle(
        key: &KeyEvent,
        catalog: &EditorCommandCatalog,
        command_palette_visible: bool,
        close_command_palette: &mut dyn FnMut(),
        perform: &mut dyn FnMut(EditorCommand),
        unavailable: &mut dyn FnMut(&EditorCommandEntry),
    ) -> bool {
        if key.is_repeat {
            return false;
        }

        // Escape dismisses the palette before anything else sees it.
        if key.scancode == Scancode::ESCAPE {
            if !command_palette_visible {
                return false;
            }
            close_command_palette();
            return true;
        }

        let Some(entry) = catalog.entry(key) else {
            return false;
        };
        // Enter belongs to the palette's text field while it is open.
        if command_palette_visible
            && entry
                .shortcut
                .as_ref()
                .is_some_and(|shortcut| shortcut.key.name == "Enter")
        {
            return false;
        }
        if EditorCommandDispatcher::is_enabled(&entry.command, entry.is_enabled) {
            perform(entry.command);
        } else {
            unavailable(&entry);
        }
        true
    }

    /// [`Self::handle`] with the default no-op `unavailable` callback.
    pub fn handle_default(
        key: &KeyEvent,
        catalog: &EditorCommandCatalog,
        command_palette_visible: bool,
        close_command_palette: &mut dyn FnMut(),
        perform: &mut dyn FnMut(EditorCommand),
    ) -> bool {
        Self::handle(
            key,
            catalog,
            command_palette_visible,
            close_command_palette,
            perform,
            &mut |_| {},
        )
    }
}
