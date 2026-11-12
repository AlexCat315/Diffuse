//! Ported from `Editor/Tests/EditorAppTests/CommandCatalogTests.swift`.

use cove_platform::{KeyEvent, KeyModifiers};
use cove_ui_compose::Scancode;
use diffuse_editor_core::contributions::workbench::contributed::WorkbenchCatalog;
use diffuse_editor_core::state::editor_state::PlaybackState;
use diffuse_editor_core::state::workspace::content::EditorContent;

use crate::commands::catalog::{
    EditorCommandCatalog, EditorCommandContext, EditorCommandDocument, EditorCommandEntry,
    EditorCommandItem, EditorCommandMenu,
};
use crate::commands::command::{EditorCommand, EditorPanelArea};
use crate::commands::policy::{EditorPlaybackCommandPolicy, EditorSceneAuthoringPolicy};
use crate::commands::shortcut::{EditorKeyModifiers, EditorShortcut, EditorShortcutKey};

fn make(playback_state: PlaybackState, content: EditorContent) -> EditorCommandCatalog {
    let mut context = EditorCommandContext::with_defaults(content);
    context.playback_state = playback_state;
    context.agent_panel_id = Some("intent-input".to_string());
    EditorCommandCatalog::make(&context)
}

fn full() -> EditorCommandCatalog {
    let mut context = EditorCommandContext::with_defaults(EditorContent::Scene);
    context.can_undo = true;
    context.can_redo = true;
    context.has_selection = true;
    context.agent_panel_id = Some("intent-input".to_string());
    EditorCommandCatalog::make(&context)
}

fn entries(items: &[EditorCommandItem]) -> Vec<EditorCommandEntry> {
    items
        .iter()
        .flat_map(|item| match item {
            EditorCommandItem::Entry(entry) => vec![entry.clone()],
            EditorCommandItem::Submenu(menu) => entries(&menu.items),
            EditorCommandItem::Separator => Vec::new(),
        })
        .collect()
}

fn submenu<'a>(id: &str, menu: &'a EditorCommandMenu) -> Option<&'a EditorCommandMenu> {
    menu.items.iter().find_map(|item| match item {
        EditorCommandItem::Submenu(nested) if nested.id == id => Some(nested),
        _ => None,
    })
}

/// Native geometry creation follows scene and playback policy.
#[test]
fn native_geometry_policy() {
    let identifiers = [
        "world.geometry.box",
        "world.geometry.plane",
        "world.geometry.curve",
    ];
    for id in identifiers {
        let stopped = make(PlaybackState::Stopped, EditorContent::Scene);
        assert!(
            stopped
                .entries()
                .iter()
                .any(|entry| entry.id == id && entry.is_enabled)
        );
        let playing = make(PlaybackState::Playing, EditorContent::Scene);
        assert!(
            playing
                .entries()
                .iter()
                .any(|entry| entry.id == id && !entry.is_enabled)
        );
        let paused = make(PlaybackState::Paused, EditorContent::Scene);
        assert!(
            paused
                .entries()
                .iter()
                .any(|entry| entry.id == id && !entry.is_enabled)
        );
        let files = make(PlaybackState::Stopped, EditorContent::Files);
        assert!(!files.entries().iter().any(|entry| entry.id == id));
    }
}

/// View lists each content with its chord, and Window holds only panels.
#[test]
fn menu_organization() {
    for content in EditorContent::ALL {
        let catalog = make(PlaybackState::Stopped, content);
        let view = catalog
            .menus
            .iter()
            .find(|menu| menu.id == "view")
            .expect("view menu");
        let contents: Vec<EditorCommandEntry> = entries(&view.items)
            .into_iter()
            .filter(|entry| entry.id.starts_with("content."))
            .collect();
        let equivalents: Vec<String> = contents
            .iter()
            .filter_map(|entry| {
                entry
                    .shortcut
                    .as_ref()
                    .map(|shortcut| shortcut.key.equivalent.clone())
            })
            .collect();
        assert_eq!(equivalents, ["1", "2", "3"]);
        let selected: Vec<&str> = contents
            .iter()
            .filter(|entry| entry.is_selected)
            .map(|entry| entry.id.as_str())
            .collect();
        assert_eq!(selected, [format!("content.{}", content.raw_value())]);
        let window = catalog
            .menus
            .iter()
            .find(|menu| menu.id == "window")
            .expect("window menu");
        assert!(
            !entries(&window.items)
                .iter()
                .any(|entry| matches!(entry.command, EditorCommand::ShowContent(_)))
        );
    }
}

/// Playback and builds stay reachable from every content.
#[test]
fn transport_everywhere() {
    for content in EditorContent::ALL {
        let ids: std::collections::BTreeSet<String> = make(PlaybackState::Stopped, content)
            .entries()
            .into_iter()
            .map(|entry| entry.id)
            .collect();
        for id in ["playback.toggle", "project.build"] {
            assert!(ids.contains(id), "{content:?} missing {id}");
        }
    }
}

/// Files hide scene editing but keep every panel.
#[test]
fn documents_scope() {
    let ids: std::collections::BTreeSet<String> =
        make(PlaybackState::Stopped, EditorContent::Files)
            .entries()
            .into_iter()
            .map(|entry| entry.id)
            .collect();
    assert!(!ids.contains("scene.settings"));
    assert!(!ids.contains("scene.save"));
    assert!(ids.contains("document.save"));
    assert!(ids.contains("panel.hierarchy"));
    assert!(ids.contains("panel.documents"));
    assert!(ids.contains("panel.files"));
    assert!(ids.contains("agent.show"));
    // Without an agent package there is no conversation to show.
    let mut no_agent = EditorCommandContext::with_defaults(EditorContent::Files);
    no_agent.agent_panel_id = None;
    assert!(
        !EditorCommandCatalog::make(&no_agent)
            .entries()
            .iter()
            .any(|entry| entry.id == "agent.show")
    );
    // ⌘S saves the open file here; scene, selection and world commands are absent.
    for absent in [
        "scene.save",
        "scene.new",
        "scene.open",
        "edit.duplicate",
        "edit.delete",
        "select.all",
        "world.frame",
    ] {
        assert!(!ids.contains(absent), "{absent} leaked into files");
    }
    let mut dirty_context = EditorCommandContext::with_defaults(EditorContent::Files);
    dirty_context.document = Some(EditorCommandDocument::new(true));
    let dirty = EditorCommandCatalog::make(&dirty_context);
    let save = dirty
        .entries()
        .into_iter()
        .find(|entry| entry.id == "document.save")
        .expect("save");
    assert_eq!(
        save.shortcut
            .as_ref()
            .map(|shortcut| shortcut.key.equivalent.clone()),
        Some("s".to_string())
    );
    assert!(save.is_enabled);
    assert!(
        !dirty
            .entries()
            .iter()
            .any(|entry| entry.id == "document.close" && entry.is_enabled)
    );
    assert!(
        !dirty
            .menus
            .iter()
            .any(|menu| menu.id == "select" || menu.id == "world")
    );
    let mut clean_context = EditorCommandContext::with_defaults(EditorContent::Files);
    clean_context.document = Some(EditorCommandDocument::new(false));
    let clean = EditorCommandCatalog::make(&clean_context);
    assert!(
        !clean
            .entries()
            .iter()
            .any(|entry| entry.id == "document.save" && entry.is_enabled)
    );
    assert!(
        clean
            .entries()
            .iter()
            .any(|entry| entry.id == "document.close" && entry.is_enabled)
    );
}

/// The scene exposes Select and World menus backed by scene commands.
#[test]
fn select_and_world() {
    let catalog = full();
    let entries = catalog.entries();
    let ids: std::collections::BTreeSet<&str> =
        entries.iter().map(|entry| entry.id.as_str()).collect();
    for id in [
        "select.all",
        "select.none",
        "select.invert",
        "select.descendants",
        "world.frame",
        "world.visibility",
        "world.lock",
        "world.add.cube",
        "world.add.camera",
        "world.geometry.box",
        "world.geometry.plane",
        "world.geometry.curve",
    ] {
        assert!(ids.contains(id), "missing {id}");
    }
    // Text fields own ⌘A; Select All must not claim it from the native menu.
    assert!(
        entries
            .iter()
            .find(|entry| entry.id == "select.all")
            .expect("select all")
            .shortcut
            .is_none()
    );
    assert!(!ids.contains("document.save"));
    let menu_ids: Vec<&str> = catalog.menus.iter().map(|menu| menu.id.as_str()).collect();
    assert_eq!(
        menu_ids,
        [
            "file", "edit", "select", "world", "view", "agent", "run", "window", "help"
        ]
    );
}

/// Exposes the core file / edit / build commands.
#[test]
fn core_commands() {
    let ids: std::collections::BTreeSet<String> =
        full().entries().into_iter().map(|entry| entry.id).collect();
    for id in [
        "project.close",
        "scene.new",
        "scene.open",
        "scene.save",
        "assets.import",
        "edit.undo",
        "edit.redo",
        "edit.duplicate",
        "edit.delete",
        "project.build",
        "project.run",
        "layout.reopen",
        "agent.intent",
        "search.resources",
        "palette.commands",
        "playback.toggle",
        "preferences",
        "app.about",
    ] {
        assert!(ids.contains(id), "missing {id}");
    }
}

/// Edit commands reflect actual history and selection availability.
#[test]
fn edit_command_availability() {
    let unavailable = ["edit.undo", "edit.redo", "edit.duplicate", "edit.delete"];
    for entry in make(PlaybackState::Stopped, EditorContent::Scene)
        .entries()
        .into_iter()
        .filter(|entry| unavailable.contains(&entry.id.as_str()))
    {
        assert!(!entry.is_enabled, "{}", entry.id);
    }
    for entry in full()
        .entries()
        .into_iter()
        .filter(|entry| unavailable.contains(&entry.id.as_str()))
    {
        assert!(entry.is_enabled, "{}", entry.id);
    }
}

/// Scene authoring commands are disabled while playing or paused.
#[test]
fn playback_disables_scene_authoring_commands() {
    for playback_state in [PlaybackState::Playing, PlaybackState::Paused] {
        let mut context = EditorCommandContext::with_defaults(EditorContent::Scene);
        context.playback_state = playback_state;
        context.can_undo = true;
        context.can_redo = true;
        context.has_selection = true;
        for entry in EditorCommandCatalog::make(&context).entries() {
            if matches!(
                entry.command,
                EditorCommand::NewScene
                    | EditorCommand::OpenScene
                    | EditorCommand::Undo
                    | EditorCommand::Redo
                    | EditorCommand::DuplicateSelection
                    | EditorCommand::DeleteSelection
                    | EditorCommand::ImportAssets
            ) {
                assert!(!entry.is_enabled, "{}", entry.id);
            }
        }
    }
    assert!(EditorSceneAuthoringPolicy::can_edit_scene(
        PlaybackState::Stopped
    ));
    assert!(!EditorSceneAuthoringPolicy::can_edit_scene(
        PlaybackState::Playing
    ));
    assert!(!EditorSceneAuthoringPolicy::can_edit_scene(
        PlaybackState::Paused
    ));
}

/// Playback state selects exactly the matching transport command.
#[test]
fn playback_selection() {
    for entry in make(PlaybackState::Playing, EditorContent::Scene).entries() {
        match entry.command {
            EditorCommand::SetPlaybackState(PlaybackState::Playing) => {
                assert!(entry.is_selected);
                assert!(!entry.is_enabled);
            }
            EditorCommand::SetPlaybackState(PlaybackState::Paused)
            | EditorCommand::SetPlaybackState(PlaybackState::Stopped) => {
                assert!(!entry.is_selected);
                assert!(entry.is_enabled);
            }
            _ => {}
        }
    }
}

/// Playback policy rejects no-op and stopped-to-paused transitions; toggle plays or pauses.
#[test]
fn playback_transition_policy() {
    use PlaybackState::{Paused, Playing, Stopped};
    assert!(EditorPlaybackCommandPolicy::can_transition(
        Stopped, Playing
    ));
    assert!(!EditorPlaybackCommandPolicy::can_transition(
        Stopped, Paused
    ));
    assert!(!EditorPlaybackCommandPolicy::can_transition(
        Stopped, Stopped
    ));
    assert!(EditorPlaybackCommandPolicy::can_transition(Playing, Paused));
    assert!(EditorPlaybackCommandPolicy::can_transition(
        Playing, Stopped
    ));
    assert!(!EditorPlaybackCommandPolicy::can_transition(
        Playing, Playing
    ));
    assert!(EditorPlaybackCommandPolicy::can_transition(Paused, Playing));
    assert!(EditorPlaybackCommandPolicy::can_transition(Paused, Stopped));
    assert!(!EditorPlaybackCommandPolicy::can_transition(Paused, Paused));
    assert_eq!(EditorPlaybackCommandPolicy::toggle_target(Stopped), Playing);
    assert_eq!(EditorPlaybackCommandPolicy::toggle_target(Playing), Paused);
    assert_eq!(EditorPlaybackCommandPolicy::toggle_target(Paused), Playing);
}

/// Stopped transport disables pause and the already-active stop command.
#[test]
fn stopped_playback_menu_availability() {
    for entry in make(PlaybackState::Stopped, EditorContent::Scene).entries() {
        match entry.command {
            EditorCommand::SetPlaybackState(PlaybackState::Playing) => assert!(entry.is_enabled),
            EditorCommand::SetPlaybackState(PlaybackState::Paused)
            | EditorCommand::SetPlaybackState(PlaybackState::Stopped) => {
                assert!(!entry.is_enabled)
            }
            _ => {}
        }
    }
}

/// Undo binds to primary+Z and delete to an unmodified Delete key.
#[test]
fn edit_shortcuts() {
    let entries = full().entries();
    let undo = entries
        .iter()
        .find(|entry| entry.id == "edit.undo")
        .expect("undo");
    let shortcut = undo.shortcut.as_ref().expect("undo shortcut");
    assert_eq!(shortcut.key.equivalent, "z");
    // `.primary` is Cmd on macOS and Ctrl elsewhere.
    assert!(shortcut.modifiers.contains(EditorKeyModifiers::primary()));
    let deletion = entries
        .iter()
        .find(|entry| entry.id == "edit.delete")
        .expect("delete");
    let shortcut = deletion.shortcut.as_ref().expect("delete shortcut");
    assert_eq!(shortcut.key.equivalent, "\u{8}");
    assert!(shortcut.modifiers.is_empty());
    assert!(deletion.is_enabled);
}

/// Ids and key chords are unique across the whole tree.
#[test]
fn uniqueness() {
    for mode in EditorContent::ALL {
        let entries = make(PlaybackState::Stopped, mode).entries();
        let ids: Vec<&str> = entries.iter().map(|entry| entry.id.as_str()).collect();
        let unique_ids: std::collections::BTreeSet<&str> = ids.iter().copied().collect();
        assert_eq!(unique_ids.len(), ids.len(), "duplicate ids in {mode:?}");
        let chords: Vec<String> = entries
            .iter()
            .filter_map(|entry| entry.shortcut.as_ref())
            .map(|shortcut| format!("{}-{}", shortcut.key.equivalent, shortcut.modifiers.0))
            .collect();
        let unique_chords: std::collections::BTreeSet<&String> = chords.iter().collect();
        assert_eq!(
            unique_chords.len(),
            chords.len(),
            "duplicate chords in {mode:?}"
        );
    }
}

/// Menus never start, end or double up on separators, and never show empty submenus.
#[test]
fn structure_hygiene() {
    fn check(items: &[EditorCommandItem], path: &str) {
        assert!(!items.is_empty(), "{path} is empty");
        assert!(
            !matches!(items.first(), Some(EditorCommandItem::Separator)),
            "{path} starts with a separator"
        );
        assert!(
            !matches!(items.last(), Some(EditorCommandItem::Separator)),
            "{path} ends with a separator"
        );
        for (index, item) in items.iter().enumerate() {
            if matches!(item, EditorCommandItem::Separator)
                && index > 0
                && matches!(items[index - 1], EditorCommandItem::Separator)
            {
                panic!("{path} repeats a separator");
            }
            if let EditorCommandItem::Submenu(menu) = item {
                check(&menu.items, &format!("{path}/{}", menu.id));
            }
        }
    }
    for mode in EditorContent::ALL {
        for playback in [
            PlaybackState::Stopped,
            PlaybackState::Playing,
            PlaybackState::Paused,
        ] {
            for menu in make(playback, mode).menus_with_application_items() {
                check(&menu.items, &format!("{mode:?}/{}", menu.id));
            }
        }
    }
}

/// Without an application menu, Settings joins Edit and About joins Help.
#[test]
fn application_item_placement() {
    let catalog = full();
    assert!(
        !catalog
            .menus
            .iter()
            .flat_map(|menu| entries(&menu.items))
            .any(|entry| entry.id == "preferences" || entry.id == "app.about")
    );
    let menus = catalog.menus_with_application_items();
    let edit = menus.iter().find(|menu| menu.id == "edit").expect("edit");
    let help = menus.iter().find(|menu| menu.id == "help").expect("help");
    assert_eq!(
        entries(&edit.items).last().map(|entry| entry.id.as_str()),
        Some("preferences")
    );
    assert_eq!(
        entries(&help.items).last().map(|entry| entry.id.as_str()),
        Some("app.about")
    );
    assert_eq!(
        catalog
            .entries()
            .iter()
            .filter(|entry| entry.id == "preferences")
            .count(),
        1
    );
}

/// Palette search lists catalog entries except the palette openers.
#[test]
fn palette_entries() {
    let palette: Vec<String> = full()
        .entries()
        .into_iter()
        .filter(|entry| entry.in_palette)
        .map(|entry| entry.id)
        .collect();
    assert!(!palette.iter().any(|id| id == "agent.intent"));
    assert!(!palette.iter().any(|id| id == "palette.commands"));
    assert!(!palette.iter().any(|id| id == "search.resources"));
    assert!(palette.iter().any(|id| id == "scene.save"));
    assert!(palette.iter().any(|id| id == "content.files"));
}

/// Shortcut labels follow the platform convention.
#[test]
fn shortcut_labels() {
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

/// Every chord resolves its physical key.
#[test]
fn key_matching() {
    fn key(scancode: u32, modifiers: KeyModifiers) -> KeyEvent {
        KeyEvent {
            scancode,
            keycode: 0,
            modifiers,
            is_repeat: false,
        }
    }
    let catalog = full();
    let entry_id = |event: &KeyEvent| catalog.entry(event).map(|entry| entry.id);
    assert_eq!(
        entry_id(&key(Scancode::S, KeyModifiers::LEFT_GUI)).as_deref(),
        Some("scene.save")
    );
    assert_eq!(
        entry_id(&key(Scancode::S, KeyModifiers::RIGHT_CTRL)).as_deref(),
        Some("scene.save")
    );
    assert_eq!(
        entry_id(&key(Scancode::Z, KeyModifiers::LEFT_GUI)).as_deref(),
        Some("edit.undo")
    );
    assert_eq!(
        entry_id(&key(
            Scancode::Z,
            KeyModifiers::LEFT_GUI | KeyModifiers::RIGHT_SHIFT
        ))
        .as_deref(),
        Some("edit.redo")
    );
    assert_eq!(
        entry_id(&key(Scancode::P, KeyModifiers::LEFT_GUI)).as_deref(),
        Some("search.resources")
    );
    assert_eq!(
        entry_id(&key(
            Scancode::P,
            KeyModifiers::LEFT_GUI | KeyModifiers::LEFT_SHIFT
        ))
        .as_deref(),
        Some("palette.commands")
    );
    assert_eq!(
        entry_id(&key(Scancode::DIGIT3, KeyModifiers::LEFT_GUI)).as_deref(),
        Some("content.timeline")
    );
    assert_eq!(
        entry_id(&key(Scancode::DIGIT0, KeyModifiers::LEFT_GUI)).as_deref(),
        Some("layout.reset")
    );
    assert_eq!(
        entry_id(&key(Scancode::KEYPAD_ENTER, KeyModifiers::LEFT_GUI)).as_deref(),
        Some("playback.toggle")
    );
    assert_eq!(
        entry_id(&key(Scancode::DELETE, KeyModifiers(0))).as_deref(),
        Some("edit.delete")
    );
    assert_eq!(
        entry_id(&key(Scancode::BACKSPACE, KeyModifiers(0))).as_deref(),
        Some("edit.delete")
    );
    // An unmodified letter or a chord with an extra Option never fires a command.
    assert!(catalog.entry(&key(Scancode::S, KeyModifiers(0))).is_none());
    assert!(
        catalog
            .entry(&key(
                Scancode::S,
                KeyModifiers::LEFT_GUI | KeyModifiers::LEFT_ALT
            ))
            .is_none()
    );
}

/// View → Panels toggles each docked edge for every content.
#[test]
fn panel_areas() {
    for mode in EditorContent::ALL {
        let catalog = make(PlaybackState::Stopped, mode);
        let view = catalog
            .menus
            .iter()
            .find(|menu| menu.id == "view")
            .expect("view");
        let panels = submenu("panels", view).expect("panels");
        let areas: Vec<EditorPanelArea> = entries(&panels.items)
            .into_iter()
            .filter_map(|entry| match entry.command {
                EditorCommand::TogglePanelArea(area) => Some(area),
                _ => None,
            })
            .collect();
        assert_eq!(
            areas,
            [
                EditorPanelArea::Leading,
                EditorPanelArea::Trailing,
                EditorPanelArea::Bottom
            ]
        );
    }
    let bottom = full()
        .entries()
        .into_iter()
        .find(|entry| entry.id == "area.bottom")
        .expect("bottom");
    assert_eq!(
        bottom.shortcut,
        Some(EditorShortcut::new(EditorShortcutKey::letter('j')))
    );
}

/// Stop has its own chord and is only available while the game runs.
#[test]
fn stop_shortcut() {
    let stop = make(PlaybackState::Playing, EditorContent::Scene)
        .entries()
        .into_iter()
        .find(|entry| entry.id == "playback.stopped")
        .expect("stop");
    assert_eq!(
        stop.shortcut,
        Some(EditorShortcut::with_modifiers(
            EditorShortcutKey::enter(),
            EditorKeyModifiers::primary() | EditorKeyModifiers::SHIFT
        ))
    );
    assert!(stop.is_enabled);
    assert!(
        !make(PlaybackState::Stopped, EditorContent::Scene)
            .entries()
            .iter()
            .any(|entry| entry.id == "playback.stopped" && entry.is_enabled)
    );
}

/// Only chords refused because the game runs are reported as blocked by playback.
#[test]
fn blocked_only_by_playback() {
    let mut playing = EditorCommandContext::with_defaults(EditorContent::Scene);
    playing.playback_state = PlaybackState::Playing;
    playing.has_selection = true;
    let catalog = EditorCommandCatalog::make(&playing);
    let duplicate = catalog
        .entries()
        .into_iter()
        .find(|entry| entry.id == "edit.duplicate")
        .expect("duplicate");
    assert!(EditorCommandCatalog::is_blocked_only_by_playback(
        &duplicate, &playing
    ));
    // Bare Delete belongs to the game while it runs.
    let delete = catalog
        .entries()
        .into_iter()
        .find(|entry| entry.id == "edit.delete")
        .expect("delete");
    assert!(!EditorCommandCatalog::is_blocked_only_by_playback(
        &delete, &playing
    ));
    // Nothing selected: playback is not the only reason.
    let mut empty = EditorCommandContext::with_defaults(EditorContent::Scene);
    empty.playback_state = PlaybackState::Playing;
    let no_selection = EditorCommandCatalog::make(&empty)
        .entries()
        .into_iter()
        .find(|entry| entry.id == "edit.duplicate")
        .expect("duplicate");
    assert!(!EditorCommandCatalog::is_blocked_only_by_playback(
        &no_selection,
        &empty
    ));
    let mut stopped = EditorCommandContext::with_defaults(EditorContent::Scene);
    stopped.has_selection = true;
    let enabled = EditorCommandCatalog::make(&stopped)
        .entries()
        .into_iter()
        .find(|entry| entry.id == "edit.duplicate")
        .expect("duplicate");
    assert!(!EditorCommandCatalog::is_blocked_only_by_playback(
        &enabled, &stopped
    ));
}
