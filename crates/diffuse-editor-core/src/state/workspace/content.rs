//! `Editor/Sources/EditorCore/State/Workspace/Content.swift` — what the center of
//! the window shows. The panels around it, the inspector's sections, the
//! commands and the assistant's tools follow it.

use serde::{Deserialize, Serialize};

use crate::state::workspace::editor_workspace_profile::EditorWorkspaceProfile;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EditorContent {
    Scene,
    Files,
    Timeline,
}

impl EditorContent {
    /// Swift's `CaseIterable` order.
    pub const ALL: [EditorContent; 3] = [
        EditorContent::Scene,
        EditorContent::Files,
        EditorContent::Timeline,
    ];

    pub fn title(self) -> &'static str {
        match self {
            EditorContent::Scene => "Scene",
            EditorContent::Files => "Code",
            EditorContent::Timeline => "Timeline",
        }
    }

    pub fn profile(self) -> EditorWorkspaceProfile {
        EditorWorkspaceProfile::profile(self)
    }

    /// The content a project tool works on, so the agent view can show it.
    pub fn touched_by_tool(name: &str) -> Option<EditorContent> {
        match name {
            "get_media_timeline"
            | "add_media_clip"
            | "trim_media_clip"
            | "remove_media_clip"
            | "save_media_timeline"
            | "export_media" => Some(EditorContent::Timeline),
            "list_files" | "read_file" | "write_file" | "get_scripting_api" | "list_scripts"
            | "read_script" | "write_script" | "compile_scripts" => Some(EditorContent::Files),
            "save_scene" | "get_runtime_state" | "set_playback_state" | "export_project" => {
                Some(EditorContent::Scene)
            }
            _ => None,
        }
    }
}
