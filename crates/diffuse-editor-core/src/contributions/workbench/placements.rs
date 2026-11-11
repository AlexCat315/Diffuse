//! `Editor/Sources/EditorCore/Contributions/Workbench/Placements.swift`.

use diffuse_plugin::contribution::workbench::document::DocumentViewContribution;

use crate::contributions::workbench::contributed::ContributedCommand;

/// A package command placed at the end of a host menu.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContributedMenuItem {
    pub command: ContributedCommand,
    /// One of the menu contribution's `menus`.
    pub menu: String,
}

/// A package command shown as an icon button on the title bar.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContributedToolbarItem {
    pub command: ContributedCommand,
    /// The name of one of the host's toolbar icons.
    pub icon: String,
}

/// One enabled `cove.ui.documentView/v1` contribution.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContributedDocumentView {
    pub plugin_id: String,
    pub id: String,
    pub title: String,
    pub extensions: Vec<String>,
    pub(crate) entry_point: String,
}

impl ContributedDocumentView {
    pub(crate) fn new(
        plugin_id: impl Into<String>,
        contribution: &DocumentViewContribution,
    ) -> Self {
        ContributedDocumentView {
            plugin_id: plugin_id.into(),
            id: contribution.id.clone(),
            title: contribution.title.clone(),
            extensions: contribution.extensions.clone(),
            entry_point: contribution.entry_point.clone(),
        }
    }
}
