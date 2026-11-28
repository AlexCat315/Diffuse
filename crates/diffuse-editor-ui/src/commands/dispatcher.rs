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

use diffuse_editor_core::state::editor_reducer::EditorAction;
use diffuse_editor_core::state::editor_state::{EditorConsoleSeverity, PlaybackState};

use crate::commands::policy::{EditorPlaybackCommandPolicy, EditorWorkspaceCommandPolicy};
use crate::commands::scene_files::EditorSceneFileCoordinator;
use crate::projects::editor_launch_context::{EditorLaunchBundle, EditorLaunchContext};
use crate::root::workspace::follower::EditorContentFollower;

impl EditorCommandDispatcher {
    /// Commands with an entry point and a live panel in the desktop workbench.
    pub fn is_wired(command: &EditorCommand) -> bool {
        use EditorCommand::*;
        matches!(
            command, OpenFolder | ActivateProject(_) | CloseProject | NewScene | OpenScene | SaveScene
                | SaveDocument | RevertDocument | CloseDocument | Undo | Redo | DuplicateSelection
                | DeleteSelection | ClearSelection | SpawnEntity(_) | FrameSelection
                | ShowContent(diffuse_editor_core::state::workspace::content::EditorContent::Files
                    | diffuse_editor_core::state::workspace::content::EditorContent::Scene)
                | SetPlaybackState(_) | TogglePlayback | ToggleTheme | BuildProject | BuildAndRun
                | RunTask(_) | OpenSettings
        )
    }

    pub fn handle(
        command: EditorCommand,
        bundle: &EditorLaunchBundle,
        context: &std::rc::Rc<EditorLaunchContext>,
    ) {
        use EditorCommand::*;
        let focus = FocusChainHolder::current();
        let edit = match command { Undo => Some(TextEditCommand::Undo), Redo => Some(TextEditCommand::Redo), _ => None };
        if let Some(edit) = edit
            && focus.as_ref().is_some_and(|focus| focus.perform_text_edit(edit))
        {
            return;
        }
        let app = &bundle.app;
        let store = &app.store;
        if store.pending_close_request().is_some()
            || focus.as_ref().is_some_and(|focus| focus.modal_root().is_some())
            || !EditorWorkspaceCommandPolicy::allows(&command, store.content())
        {
            return;
        }
        match command {
            OpenFolder => context.request_open_folder(),
            ActivateProject(path) => {
                if let Err(error) = context.activate(&path) {
                    app.log_console("Could not open project", EditorConsoleSeverity::Error,
                        Some(error.to_string()), None, None);
                }
            }
            CloseProject => app.request_close_project(),
            NewScene => app.request_new_scene(),
            OpenScene => EditorSceneFileCoordinator::request_open(app),
            SaveScene => { app.save_scene_manifest(); }
            SaveDocument => {
                if let Some(path) = app.workstation.documents.selected_path() {
                    app.save_document_formatting(&path);
                }
            }
            RevertDocument => {
                if let Some(path) = app.workstation.documents.selected_path() {
                    app.workstation.revert_document(&path);
                }
            }
            CloseDocument => {
                if let Some(path) = app.workstation.documents.selected_path() {
                    app.workstation.close_document(&path, false);
                }
            }
            Undo => { app.undo(); }
            Redo => { app.redo(); }
            DuplicateSelection if store.playback_state() == PlaybackState::Stopped => {
                if let Some(id) = store.selected_entity_id().filter(|id| !app.scene.is_entity_locked(*id))
                    && let Some(id) = app.scene.duplicate_entity(id)
                {
                    store.dispatch(EditorAction::SetSelectedEntity(Some(id)));
                }
            }
            DeleteSelection if store.playback_state() == PlaybackState::Stopped => {
                let selected = store.selected_entity_ids();
                if !selected.is_empty()
                    && selected.iter().all(|id| !app.scene.is_entity_locked(*id))
                    && app.scene.delete_entities(&selected)
                {
                    store.dispatch(EditorAction::SetSelectedEntity(None));
                }
            }
            ClearSelection => store.dispatch(EditorAction::SetSelectedEntity(None)),
            SpawnEntity(template) if store.playback_state() == PlaybackState::Stopped => {
                if let Some(id) = app.scene.spawn_entity_default(template) {
                    store.dispatch(EditorAction::SetSelectedEntity(Some(id)));
                }
            }
            FrameSelection => app.scene.frame_entities_default(&store.selected_entity_ids()),
            ShowContent(content) => {
                EditorContentFollower::show(content, app, &mut bundle.controller.borrow_mut());
            }
            SetPlaybackState(next) => {
                if EditorPlaybackCommandPolicy::can_transition(store.playback_state(), next) {
                    app.apply_playback_state(next);
                }
            }
            TogglePlayback => {
                let next = EditorPlaybackCommandPolicy::toggle_target(store.playback_state());
                if EditorPlaybackCommandPolicy::can_transition(store.playback_state(), next) {
                    app.apply_playback_state(next);
                }
            }
            ToggleTheme => {
                use diffuse_editor_core::state::editor_state::EditorThemeMode;
                let mode = if store.presentation().theme_mode == EditorThemeMode::Dark {
                    EditorThemeMode::Light
                } else {
                    EditorThemeMode::Dark
                };
                store.dispatch(EditorAction::SetThemeMode(mode));
            }
            BuildProject => app.request_project_export(false),
            BuildAndRun => app.request_project_export(true),
            RunTask(kind) => {
                use diffuse_editor_core::tasks::results::TaskKind;
                if app.workstation.tasks.snapshot().is_available() {
                    if kind == TaskKind::Test {
                        app.workstation.tasks.test(None);
                    } else {
                        app.workstation.tasks.build();
                    }
                }
            }
            OpenSettings => context.open_settings_window(app),
            _ => {}
        }
        app.request_display_refresh();
    }
}
