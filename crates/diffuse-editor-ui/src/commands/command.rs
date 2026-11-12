//! `Editor/Sources/EditorUI/Commands/Command.swift`.
//!
//! Every user-invokable editor action. Menus, the title-bar menu, the command
//! palette and keyboard shortcuts all resolve to these values.

use diffuse_editor_core::geometry::editor_geometry_authoring::EditorGeometryPreset;
use diffuse_editor_core::scene::adapter::spawn::EditorEntityTemplate;
use diffuse_editor_core::state::editor_state::PlaybackState;
use diffuse_editor_core::state::workspace::content::EditorContent;
use diffuse_editor_core::tasks::results::TaskKind;

use crate::ai::surface::EditorStudioView;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EditorCommand {
    ShowCommandPalette(EditorPaletteScope),
    ShowSceneSettings,
    ShowAssets,
    ShowProblems,
    ShowPanel(String),
    MaximizePanel(String),
    RestorePanels,
    TogglePanelArea(EditorPanelArea),
    /// The activity rail: open the panel, or collapse its group when it is already showing.
    TogglePanel(String),
    SaveLayout,
    OpenFolder,
    /// Brings another open project to the front, by its folder.
    ActivateProject(String),
    CloseProject,
    NewScene,
    OpenScene,
    SaveScene,
    SaveDocument,
    RevertDocument,
    CloseDocument,
    ImportAssets,
    Undo,
    Redo,
    DuplicateSelection,
    DeleteSelection,
    SelectAll,
    ClearSelection,
    InvertSelection,
    SelectDescendants,
    SpawnEntity(EditorEntityTemplate),
    CreateGeometry(EditorGeometryPreset),
    FrameSelection,
    ToggleSelectionVisibility,
    ToggleSelectionLock,
    ShowContent(EditorContent),
    FocusAssistant,
    ShowView(EditorStudioView),
    ToggleView,
    ResetLayout,
    ReopenClosedPanel,
    SetPlaybackState(PlaybackState),
    TogglePlayback,
    OpenSettings,
    ToggleTheme,
    BuildProject,
    BuildAndRun,
    /// The project's build or test task, from the plugin that contributes tasks for it.
    RunTask(TaskKind),
    /// A command an enabled package contributes, by its name within the package.
    Plugin {
        plugin_id: String,
        name: String,
    },
    OpenDocumentation,
    About,
}

impl EditorCommand {
    pub fn is_about(&self) -> bool {
        matches!(self, EditorCommand::About)
    }
}

/// What the unified ⌘K field searches when it opens.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EditorPaletteScope {
    /// Plain text is a request for the Agent; commands and resources still match.
    Intent,
    Commands,
    Resources,
    Entities,
}

impl EditorPaletteScope {
    pub const ALL: [EditorPaletteScope; 4] = [
        EditorPaletteScope::Intent,
        EditorPaletteScope::Commands,
        EditorPaletteScope::Resources,
        EditorPaletteScope::Entities,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            EditorPaletteScope::Intent => "intent",
            EditorPaletteScope::Commands => "commands",
            EditorPaletteScope::Resources => "resources",
            EditorPaletteScope::Entities => "entities",
        }
    }

    pub fn prefix(self) -> &'static str {
        match self {
            EditorPaletteScope::Intent => "",
            EditorPaletteScope::Commands => ">",
            EditorPaletteScope::Resources => "@",
            EditorPaletteScope::Entities => "#",
        }
    }

    /// The scope a typed query asks for, read from its leading prefix.
    pub fn from_query(query: &str) -> Self {
        let raw = query.trim_matches(|c: char| c.is_whitespace());
        Self::ALL
            .into_iter()
            .find(|scope| !scope.prefix().is_empty() && raw.starts_with(scope.prefix()))
            .unwrap_or(EditorPaletteScope::Intent)
    }
}

/// A docked edge of the workbench that collapses and expands as a whole.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EditorPanelArea {
    Leading,
    Trailing,
    Bottom,
}

impl EditorPanelArea {
    pub const ALL: [EditorPanelArea; 3] = [
        EditorPanelArea::Leading,
        EditorPanelArea::Trailing,
        EditorPanelArea::Bottom,
    ];
}
