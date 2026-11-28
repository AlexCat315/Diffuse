//! Center content routing from EditorContentFollower.swift.

use cove_ui_addons::workspace::{WorkspaceCommand, WorkspaceController, WorkspacePanelID};
use diffuse_editor_core::application::editor_application::EditorApplication;
use diffuse_editor_core::state::editor_reducer::EditorAction;
use diffuse_editor_core::state::workspace::content::EditorContent;

pub struct EditorContentFollower;

impl EditorContentFollower {
    pub const SCENE_TOOLS: [&'static str; 2] = ["animation", "render-pipeline"];

    pub fn panel(content: EditorContent) -> WorkspacePanelID {
        match content {
            EditorContent::Scene => "viewport",
            EditorContent::Files => "documents",
            EditorContent::Timeline => "media",
        }.into()
    }

    pub fn is_content_panel(id: &WorkspacePanelID) -> bool {
        EditorContent::ALL.into_iter().any(|content| Self::panel(content) == *id)
    }

    pub fn is_placed_by_content(id: &WorkspacePanelID) -> bool {
        Self::is_content_panel(id) || Self::SCENE_TOOLS.contains(&id.as_str())
    }

    pub fn show(content: EditorContent, app: &EditorApplication, controller: &mut WorkspaceController) -> bool {
        let id = Self::panel(content);
        let mut document = controller.document().clone();
        if !document.panels.contains_key(&id) {
            return false;
        }
        if document.group_containing(&id).is_none() {
            let Some(group) = document.groups.values_mut()
                .find(|group| group.panels.iter().any(Self::is_content_panel)) else { return false };
            group.panels.retain(|panel| !Self::is_content_panel(panel));
            group.panels.insert(0, id.clone());
            group.active_panel_id = Some(id.clone());
            controller.dispatch(WorkspaceCommand::ReplaceDocument(Box::new(document)));
        }
        let Some(group) = controller.document().group_containing(&id).cloned() else { return false };
        if controller.maximized_panel_id().is_some_and(|panel| *panel != id) {
            controller.dispatch(WorkspaceCommand::RestoreMaximized);
        }
        if group.is_collapsed {
            controller.dispatch(WorkspaceCommand::Expand(group.id.clone()));
        }
        controller.dispatch(WorkspaceCommand::SetActivePanel { group_id: group.id, panel_id: id });
        app.store.dispatch(EditorAction::SetContent(content));
        true
    }
}
