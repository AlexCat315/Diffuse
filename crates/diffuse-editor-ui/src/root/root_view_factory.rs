//! `Editor/Sources/EditorUI/Root/RootViewFactory.swift`.
//!
//! The panel titles commands and the workbench share. The rest of the factory —
//! panel descriptors, layout persistence and shell state — follows in later
//! batches.

use crate::localization::localized;

/// The title the tab and every command use for a panel identifier.
pub fn localized_panel_title(id: &str) -> String {
    let key = match id {
        "hierarchy" => "Outline",
        "details" => "Properties",
        "viewport" => "Scene",
        "console" => "Console",
        "terminal" => "Terminal",
        "assets" => "Assets",
        "render-pipeline" => "Render Pipeline",
        "developer-tools" => "Developer Tools",
        "profiler" => "Profiler",
        "animation" => "Animation",
        "files" => "Files",
        "documents" => "Editor",
        "media" => "Video Editing",
        "source-control" => "Source Control",
        "sidebar" => "Sidebar",
        "tasks" => "Tasks",
        _ => return id.to_string(),
    };
    localized(key)
}

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use cove_logging::{Level, LogEvent, LogSystem};
use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use diffuse_assets::swift_json;
use diffuse_editor_core::ai::chat::editor_ai_settings::{EditorAISettings, EditorCapabilitySettings};
use diffuse_editor_core::application::editor_application::EditorApplication;
use diffuse_editor_core::contributions::themes::theme_catalog::EditorThemeCatalog;
use diffuse_editor_core::localization::EditorLocalizationPreferences;
use diffuse_editor_core::projects::editor_scratch_workspace::application_support_directory;
use diffuse_editor_core::state::editor_reducer::EditorAction;
use diffuse_editor_core::state::editor_state::{
    EditorLanguage, EditorThemeMode, EditorVSyncMode, SelectionPrimaryModifierBehavior,
};
use diffuse_editor_core::state::editor_store::EditorStore;
use serde::{Deserialize, Serialize};

const SHELL_FILE: &str = "editor_shell_state.json";
const LOG_TARGET: &str = "com.cove.editor.persistence";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "ShellStateFields")]
pub struct EditorShellState {
    #[serde(rename = "themeID")]
    pub theme_id: String,
    pub theme_mode: EditorThemeMode,
    pub language: EditorLanguage,
    pub vsync_mode: EditorVSyncMode,
    pub primary_select_behavior: SelectionPrimaryModifierBehavior,
    pub ai_settings: EditorAISettings,
    pub capability_settings: EditorCapabilitySettings,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShellStateFields {
    #[serde(rename = "themeID")]
    theme_id: Option<String>,
    theme_mode: Option<EditorThemeMode>,
    language: Option<EditorLanguage>,
    vsync_mode: Option<EditorVSyncMode>,
    primary_select_behavior: Option<SelectionPrimaryModifierBehavior>,
    ai_settings: Option<EditorAISettings>,
    capability_settings: Option<EditorCapabilitySettings>,
}

impl From<ShellStateFields> for EditorShellState {
    fn from(fields: ShellStateFields) -> Self {
        Self {
            theme_id: fields.theme_id.unwrap_or_else(|| EditorThemeCatalog::DEFAULT_THEME_ID.to_owned()),
            theme_mode: fields.theme_mode.unwrap_or(EditorThemeMode::Dark),
            language: fields.language.unwrap_or(EditorLanguage::System),
            vsync_mode: fields.vsync_mode.unwrap_or(EditorVSyncMode::Enabled),
            primary_select_behavior: fields.primary_select_behavior
                .unwrap_or(SelectionPrimaryModifierBehavior::Subtract),
            ai_settings: fields.ai_settings.unwrap_or_default(),
            capability_settings: fields.capability_settings.unwrap_or_default(),
        }
    }
}

impl EditorShellState {
    pub fn from_store(store: &EditorStore) -> Self {
        let presentation = store.presentation();
        Self {
            theme_id: presentation.theme_id,
            theme_mode: presentation.theme_mode,
            language: store.language(),
            vsync_mode: store.vsync_mode(),
            primary_select_behavior: store.primary_select_behavior(),
            ai_settings: store.ai_settings(),
            capability_settings: store.capability_settings(),
        }
    }

    pub fn apply(&self, app: &EditorApplication) {
        EditorLocalizationPreferences::set_language(self.language);
        for action in [
            EditorAction::SetThemeMode(self.theme_mode),
            EditorAction::SetThemeID(self.theme_id.clone()),
            EditorAction::SetLanguage(self.language),
            EditorAction::SetVSyncMode(self.vsync_mode),
            EditorAction::SetPrimarySelectBehavior(self.primary_select_behavior),
        ] {
            app.store.dispatch(action);
        }
        if app.store.capability_settings() != self.capability_settings {
            app.apply_capability_settings(self.capability_settings.clone());
        }
    }

    pub fn load(directory: &Path) -> Option<Self> {
        let path = directory.join(SHELL_FILE);
        match fs::read(&path) {
            Ok(bytes) => match serde_json::from_slice(&bytes) {
                Ok(state) => Some(state),
                Err(error) => {
                    quarantine_persistence_file(&path, "shell state", &error.to_string());
                    None
                }
            },
            Err(error) => {
                if error.kind() != io::ErrorKind::NotFound {
                    log_persistence_error(format!("Could not read shell state at {}: {error}", path.display()));
                }
                None
            }
        }
    }

    pub fn save(&self, directory: &Path) {
        let result = (|| -> Result<(), Box<dyn std::error::Error>> {
            let data = swift_json::to_sorted_pretty(self)?;
            AtomicFile::write(data.as_bytes(), &directory.join(SHELL_FILE), Access::Inherit)?;
            Ok(())
        })();
        if let Err(error) = result {
            log_persistence_error(format!("Could not save shell state: {error}"));
        }
    }
}

/// The application support directory is shared across all workspaces in one window.
pub fn persistence_directory(override_path: Option<&str>) -> io::Result<PathBuf> {
    let directory = override_path.filter(|path| !path.is_empty())
        .map(PathBuf::from).unwrap_or_else(|| application_support_directory().join("Cove"));
    fs::create_dir_all(&directory)?;
    Ok(directory)
}

pub fn quarantine_persistence_file(path: &Path, label: &str, reason: &str) -> Option<PathBuf> {
    let stem = path.file_stem()?.to_string_lossy();
    let extension = path.extension().map(|name| format!(".{}", name.to_string_lossy())).unwrap_or_default();
    let backup = path.with_file_name(format!(
        "{stem}.corrupt-{}{extension}",
        diffuse_kernel::codable::new_uuid(),
    ));
    match fs::rename(path, &backup) {
        Ok(()) => {
            log_persistence_error(format!("Moved invalid {label} to {}: {reason}", backup.display()));
            Some(backup)
        }
        Err(error) => {
            log_persistence_error(format!(
                "Could not quarantine invalid {label} at {}: {error}. Original error: {reason}",
                path.display(),
            ));
            None
        }
    }
}

fn log_persistence_error(message: String) {
    LogSystem::logger(LOG_TARGET).log(&LogEvent::new(Level::Error, message));
}

use std::rc::Rc;

use cove_ui_addons::workspace::{WorkspacePanelDescriptor, WorkspacePanelID, WorkspacePanelRegistry, WorkspaceSlotID};
use cove_ui_compose::{AnyView, Scope, View};

use crate::panels::console::editor_output_panel::EditorOutputPanel;
use crate::panels::documents::editor::DocumentEditorPanel;
use crate::panels::documents::files::DocumentFilesPanel;
use crate::panels::hierarchy::hierarchy_panel::HierarchyPanel;
use crate::panels::tasks::runner::TasksPanel;
use crate::panels::viewport::editor_viewport_workspace_panel::EditorViewportWorkspacePanel;
use diffuse_editor_core::state::workspace::content::EditorContent;

pub fn make_workspace_registry(app: &Rc<EditorApplication>) -> WorkspacePanelRegistry {
    let sidebar = WorkspacePanelDescriptor::new(WorkspacePanelID::from("sidebar"), localized_panel_title("sidebar"))
        .default_slot(WorkspaceSlotID::leading())
        .configure(|panel| { panel.is_closable = false; panel.hides_tab_bar_when_alone = true; })
        .content({
            let app = app.clone();
            move || AnyView::new(EditorWorkspaceSidebar(app.clone()))
        });
    let scene = WorkspacePanelDescriptor::new(WorkspacePanelID::from("viewport"), localized_panel_title("viewport"))
        .configure(|panel| {
            panel.is_closable = false;
            panel.is_collapsible = false;
            panel.hides_tab_bar_when_alone = true;
        })
        .content({
            let app = app.clone();
            move || AnyView::new(EditorViewportWorkspacePanel(app.clone()))
        });
    let documents = WorkspacePanelDescriptor::new(WorkspacePanelID::from("documents"), localized_panel_title("documents"))
        .configure(|panel| {
            panel.is_closable = false;
            panel.is_collapsible = false;
            panel.hides_tab_bar_when_alone = true;
        })
        .content({
            let app = app.clone();
            move || AnyView::new(DocumentEditorPanel::new(app.clone()))
        });
    let console = WorkspacePanelDescriptor::new(WorkspacePanelID::from("console"), localized_panel_title("console"))
        .default_slot(WorkspaceSlotID::bottom())
        .content({
            let app = app.clone();
            move || AnyView::new(EditorOutputPanel(app.clone()))
        });
    let tasks = WorkspacePanelDescriptor::new(WorkspacePanelID::from("tasks"), localized_panel_title("tasks"))
        .default_slot(WorkspaceSlotID::bottom())
        .content({
            let app = app.clone();
            move || AnyView::new(TasksPanel::new(&app))
        });
    WorkspacePanelRegistry::new([sidebar, scene, documents, console, tasks])
}

struct EditorWorkspaceSidebar(Rc<EditorApplication>);

impl View for EditorWorkspaceSidebar {
    fn body(&self, _scope: &Scope) -> AnyView {
        if self.0.store.content() == EditorContent::Scene {
            AnyView::new(HierarchyPanel(self.0.clone()))
        } else {
            AnyView::new(DocumentFilesPanel(self.0.workstation.documents.clone()))
        }
    }
}
