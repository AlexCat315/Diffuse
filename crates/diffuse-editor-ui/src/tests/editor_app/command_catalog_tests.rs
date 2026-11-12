//! Ported from `Editor/Tests/EditorAppTests/CommandCatalogTests.swift`.
//!
//! Only `shortcutLabels` is translated: `EditorCommandCatalog`,
//! `EditorCommandContext`, `EditorCommandEntry`, `EditorCommandItem`,
//! `EditorCommandMenu`, `EditorPanelArea`, `EditorPlaybackCommandPolicy`
//! (`PlaybackState::can_transition` exists, `toggle_target` does not) and
//! `EditorSceneAuthoringPolicy` have no Rust counterpart yet (`commands/catalog.rs`,
//! `command.rs` and `policy.rs` are empty placeholders), so the remaining 20
//! cases stay blocked.

/// Shortcut labels follow the platform convention.
#[test]
fn shortcut_labels() {
    use crate::commands::shortcut::{EditorKeyModifiers, EditorShortcut, EditorShortcutKey};

    let redo = EditorShortcut::with_modifiers(
        EditorShortcutKey::letter('z'),
        EditorKeyModifiers::primary() | EditorKeyModifiers::SHIFT,
    );
    let deletion =
        EditorShortcut::with_modifiers(EditorShortcutKey::delete(), EditorKeyModifiers::default());
    #[cfg(target_os = "macos")]
    {
        assert_eq!(redo.label(), "⇧⌘Z");
        assert_eq!(deletion.label(), "⌫");
    }
    #[cfg(not(target_os = "macos"))]
    {
        assert_eq!(redo.label(), "Ctrl+Shift+Z");
        assert_eq!(deletion.label(), "Delete");
    }
}
