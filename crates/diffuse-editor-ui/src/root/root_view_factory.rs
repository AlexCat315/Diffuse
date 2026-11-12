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
