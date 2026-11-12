//! Ported from `Editor/Tests/EditorAppTests/ShortcutHandlerTests.swift`.

use std::cell::RefCell;

use cove_platform::{KeyEvent, KeyModifiers};
use cove_ui_compose::Scancode;
use diffuse_editor_core::state::workspace::content::EditorContent;

use crate::commands::catalog::{EditorCommandCatalog, EditorCommandContext};
use crate::root::chrome::shortcut_handler::EditorShortcutHandler;

#[derive(Default)]
struct Recorder {
    performed: RefCell<Vec<String>>,
    closed_palette: RefCell<usize>,
}

fn default_context() -> EditorCommandContext {
    EditorCommandContext::new(
        EditorContent::Scene,
        diffuse_editor_core::state::editor_state::PlaybackState::Stopped,
        true,
        true,
        true,
        None,
        diffuse_editor_core::contributions::workbench::contributed::WorkbenchCatalog::empty(),
        Some("intent-input".to_string()),
    )
}

fn fire(
    key: KeyEvent,
    recorder: &Recorder,
    context: EditorCommandContext,
    palette_visible: bool,
) -> bool {
    let catalog = EditorCommandCatalog::make(&context);
    let ids = catalog
        .entries()
        .into_iter()
        .map(|entry| (entry.command, entry.id))
        .collect::<Vec<_>>();
    let performed = &recorder.performed;
    let closed = &recorder.closed_palette;
    EditorShortcutHandler::handle_default(
        &key,
        &catalog,
        palette_visible,
        &mut || *closed.borrow_mut() += 1,
        &mut |command| {
            let id = ids
                .iter()
                .find(|(candidate, _)| candidate == &command)
                .map(|(_, id)| id.clone())
                .unwrap_or_else(|| format!("{command:?}"));
            performed.borrow_mut().push(id);
        },
    )
}

fn key(scancode: u32, modifiers: KeyModifiers) -> KeyEvent {
    KeyEvent {
        scancode,
        keycode: 0,
        modifiers,
        is_repeat: false,
    }
}

/// Delete and Backspace dispatch after focused controls fall through.
#[test]
fn global_delete_shortcuts_dispatch() {
    let recorder = Recorder::default();
    assert!(fire(
        key(Scancode::DELETE, KeyModifiers(0)),
        &recorder,
        default_context(),
        false
    ));
    assert!(fire(
        key(Scancode::BACKSPACE, KeyModifiers(0)),
        &recorder,
        default_context(),
        false
    ));
    assert_eq!(*recorder.performed.borrow(), ["edit.delete", "edit.delete"]);
}

/// Advertised file, edit, and build shortcuts dispatch globally.
#[test]
fn advertised_menu_shortcuts_dispatch() {
    let recorder = Recorder::default();
    for scancode in [
        Scancode::N,
        Scancode::O,
        Scancode::D,
        Scancode::B,
        Scancode::R,
    ] {
        assert!(fire(
            key(scancode, KeyModifiers::LEFT_GUI),
            &recorder,
            default_context(),
            false
        ));
    }
    assert_eq!(
        *recorder.performed.borrow(),
        [
            "scene.new",
            "scene.open",
            "edit.duplicate",
            "project.build",
            "project.run"
        ]
    );
}

/// Single left or right modifiers trigger chords.
#[test]
fn single_sided_modifier_matches() {
    let recorder = Recorder::default();
    assert!(fire(
        key(Scancode::S, KeyModifiers::LEFT_GUI),
        &recorder,
        default_context(),
        false
    ));
    assert!(fire(
        key(Scancode::COMMA, KeyModifiers::LEFT_GUI),
        &recorder,
        default_context(),
        false
    ));
    assert!(fire(
        key(Scancode::K, KeyModifiers::RIGHT_GUI),
        &recorder,
        default_context(),
        false
    ));
    assert!(fire(
        key(Scancode::S, KeyModifiers::RIGHT_CTRL),
        &recorder,
        default_context(),
        false
    ));
    assert_eq!(
        *recorder.performed.borrow(),
        ["scene.save", "preferences", "agent.intent", "scene.save"]
    );
}

/// Cmd+Z undoes, Cmd+Shift+Z with one shift key redoes.
#[test]
fn undo_redo() {
    let recorder = Recorder::default();
    assert!(fire(
        key(Scancode::Z, KeyModifiers::LEFT_GUI),
        &recorder,
        default_context(),
        false
    ));
    assert!(fire(
        key(
            Scancode::Z,
            KeyModifiers::LEFT_GUI | KeyModifiers::LEFT_SHIFT
        ),
        &recorder,
        default_context(),
        false
    ));
    assert_eq!(*recorder.performed.borrow(), ["edit.undo", "edit.redo"]);
}

/// Cmd+Shift+T reopens the last closed panel.
#[test]
fn reopen_panel() {
    let recorder = Recorder::default();
    assert!(fire(
        key(
            Scancode::T,
            KeyModifiers::LEFT_GUI | KeyModifiers::LEFT_SHIFT
        ),
        &recorder,
        default_context(),
        false
    ));
    assert_eq!(*recorder.performed.borrow(), ["layout.reopen"]);
}

/// Content and palette chords open their destinations.
#[test]
fn content_and_palette() {
    let recorder = Recorder::default();
    assert!(fire(
        key(Scancode::DIGIT1, KeyModifiers::LEFT_GUI),
        &recorder,
        default_context(),
        false
    ));
    assert!(fire(
        key(Scancode::DIGIT3, KeyModifiers::LEFT_GUI),
        &recorder,
        default_context(),
        false
    ));
    assert!(fire(
        key(Scancode::P, KeyModifiers::LEFT_GUI),
        &recorder,
        default_context(),
        false
    ));
    assert!(fire(
        key(
            Scancode::P,
            KeyModifiers::LEFT_GUI | KeyModifiers::LEFT_SHIFT
        ),
        &recorder,
        default_context(),
        false
    ));
    assert_eq!(
        *recorder.performed.borrow(),
        [
            "content.scene",
            "content.timeline",
            "search.resources",
            "palette.commands"
        ]
    );
}

/// Unmodified keys and key repeats fall through.
#[test]
fn unmodified_ignored() {
    let recorder = Recorder::default();
    assert!(!fire(
        key(Scancode::S, KeyModifiers(0)),
        &recorder,
        default_context(),
        false
    ));
    let mut repeated = key(Scancode::S, KeyModifiers::LEFT_GUI);
    repeated.is_repeat = true;
    assert!(!fire(repeated, &recorder, default_context(), false));
    assert!(recorder.performed.borrow().is_empty());
}

/// Disabled commands consume their chord without running.
#[test]
fn disabled_commands_do_not_run() {
    let recorder = Recorder::default();
    let empty = EditorCommandContext::with_defaults(EditorContent::Scene);
    assert!(fire(
        key(Scancode::DELETE, KeyModifiers(0)),
        &recorder,
        empty.clone(),
        false
    ));
    assert!(fire(
        key(Scancode::D, KeyModifiers::LEFT_GUI),
        &recorder,
        empty,
        false
    ));
    assert!(recorder.performed.borrow().is_empty());
}

/// Commands outside the content never match.
#[test]
fn workspace_scoped_chords() {
    let recorder = Recorder::default();
    let files = EditorCommandContext::with_defaults(EditorContent::Files);
    assert!(!fire(
        key(Scancode::N, KeyModifiers::LEFT_GUI),
        &recorder,
        files.clone(),
        false
    ));
    assert!(!fire(
        key(Scancode::O, KeyModifiers::LEFT_GUI),
        &recorder,
        files,
        false
    ));
    assert!(recorder.performed.borrow().is_empty());
}

/// Escape closes the palette, and Enter stays with the palette field.
#[test]
fn palette_keys() {
    let recorder = Recorder::default();
    assert!(!fire(
        key(Scancode::ESCAPE, KeyModifiers(0)),
        &recorder,
        default_context(),
        false
    ));
    assert!(fire(
        key(Scancode::ESCAPE, KeyModifiers(0)),
        &recorder,
        default_context(),
        true
    ));
    assert_eq!(*recorder.closed_palette.borrow(), 1);
    assert!(!fire(
        key(Scancode::RETURN, KeyModifiers::LEFT_GUI),
        &recorder,
        default_context(),
        true
    ));
    assert!(fire(
        key(Scancode::RETURN, KeyModifiers::LEFT_GUI),
        &recorder,
        default_context(),
        false
    ));
    assert_eq!(*recorder.performed.borrow(), ["playback.toggle"]);
}
