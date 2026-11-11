//! `Editor/Sources/EditorCore/Contributions/Workbench/Contributed.swift`.

use std::collections::BTreeSet;
use std::path::Path;

use diffuse_plugin::contract::plugin_package::ValidatedPluginPackage;
use diffuse_plugin::contribution::workbench::command::CommandContributionPoint;
use diffuse_plugin::contribution::workbench::document::DocumentViewContributionPoint;
use diffuse_plugin::contribution::workbench::panel::{
    PanelContent, PanelContribution, PanelContributionPoint,
};
use diffuse_plugin::contribution::workbench::placement::{
    MenuContributionPoint, ToolbarContributionPoint,
};

use crate::contributions::workbench::placements::{
    ContributedDocumentView, ContributedMenuItem, ContributedToolbarItem,
};

/// A view the host provides for a plugin panel to name.
///
/// Open on purpose. A package names the view it wants through
/// `cove.ui.panel/v1`, so the editor never keeps a list of the plugins allowed
/// to add one — and never needs a flag per plugin to ask whether it is there.
/// The host decides which named views it can draw; a name it cannot draw stays
/// an ordinary workbench panel.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct WorkbenchView {
    pub raw_value: String,
}

impl WorkbenchView {
    pub fn new(raw_value: impl Into<String>) -> Self {
        WorkbenchView {
            raw_value: raw_value.into(),
        }
    }

    /// The agent conversation. It exists because a package declared a panel for
    /// it, not because a particular plugin is switched on.
    pub fn agent() -> Self {
        Self::new("agent")
    }
}

/// One enabled `cove.command/v1` contribution.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContributedCommand {
    pub plugin_id: String,
    pub title: String,
    pub keywords: String,
    pub shows_in_palette: bool,
    /// The identifier within its package, which the package's panels use.
    pub name: String,
    pub(crate) entry_point: String,
}

impl ContributedCommand {
    /// Unique across packages, so two packages may both name a command `refresh`.
    pub fn id(&self) -> String {
        format!("{}.{}", self.plugin_id, self.name)
    }

    pub(crate) fn new(
        plugin_id: impl Into<String>,
        contribution: &diffuse_plugin::contribution::workbench::command::CommandContribution,
    ) -> Self {
        ContributedCommand {
            plugin_id: plugin_id.into(),
            title: contribution.title.clone(),
            keywords: contribution.keywords.clone().unwrap_or_default(),
            shows_in_palette: contribution.palette.unwrap_or(true),
            name: contribution.id.clone(),
            entry_point: contribution.entry_point.clone(),
        }
    }
}

/// One enabled `cove.ui.panel/v1` contribution.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ContributedPanel {
    pub plugin_id: String,
    /// The workspace panel identifier; unique among enabled packages.
    pub id: String,
    pub title: String,
    pub slot: String,
    pub icon: Option<String>,
    pub content: ContributedPanelContent,
    pub surface: Option<String>,
    pub in_surface: Option<String>,
    pub(crate) entry_point: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ContributedPanelContent {
    View(WorkbenchView),
    /// The plugin describes the content as a panel model.
    Model,
}

impl ContributedPanel {
    pub(crate) fn new(
        plugin_id: impl Into<String>,
        contribution: &PanelContribution,
    ) -> Option<Self> {
        let (content, entry_point) = match contribution.content() {
            // Any name is accepted here: whether the host can draw it is the
            // host's decision, not a reason to drop the contribution.
            PanelContent::View(name) => (
                ContributedPanelContent::View(WorkbenchView::new(name)),
                None,
            ),
            PanelContent::EntryPoint(entry_point) => {
                (ContributedPanelContent::Model, Some(entry_point))
            }
        };
        Some(ContributedPanel {
            plugin_id: plugin_id.into(),
            id: contribution.id.clone(),
            title: contribution.title.clone(),
            slot: contribution
                .slot
                .clone()
                .unwrap_or_else(|| "trailing".to_string()),
            icon: contribution.icon.clone(),
            content,
            surface: contribution.surface.clone(),
            in_surface: contribution.in_surface.clone(),
            entry_point,
        })
    }
}

/// Everything enabled packages add to the workbench, for one editor session.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct WorkbenchCatalog {
    pub commands: Vec<ContributedCommand>,
    pub panels: Vec<ContributedPanel>,
    pub menu_items: Vec<ContributedMenuItem>,
    pub toolbar_items: Vec<ContributedToolbarItem>,
    pub document_views: Vec<ContributedDocumentView>,
}

impl WorkbenchCatalog {
    /// `WorkbenchCatalog.empty`.
    pub fn empty() -> Self {
        Self::default()
    }

    /// Each package contributes whatever workbench points it declares.
    pub fn from_packages(packages: &[ValidatedPluginPackage]) -> Self {
        let mut packages: Vec<&ValidatedPluginPackage> = packages.iter().collect();
        packages.sort_by(|lhs, rhs| lhs.manifest.id.cmp(&rhs.manifest.id));

        let commands: Vec<ContributedCommand> = packages
            .iter()
            .flat_map(|package| {
                package
                    .manifest
                    .contributes
                    .decode_lossy::<CommandContributionPoint>()
                    .into_iter()
                    .map(|contribution| {
                        ContributedCommand::new(&package.manifest.id, &contribution)
                    })
                    .collect::<Vec<_>>()
            })
            .collect();
        let find_command = |plugin_id: &str, name: &str| -> Option<ContributedCommand> {
            commands
                .iter()
                .find(|command| command.plugin_id == plugin_id && command.name == name)
                .cloned()
        };
        let panels: Vec<ContributedPanel> = packages
            .iter()
            .flat_map(|package| {
                package
                    .manifest
                    .contributes
                    .decode_lossy::<PanelContributionPoint>()
                    .into_iter()
                    .filter_map(|contribution| {
                        ContributedPanel::new(&package.manifest.id, &contribution)
                    })
                    .collect::<Vec<_>>()
            })
            .collect();
        let menu_items: Vec<ContributedMenuItem> = packages
            .iter()
            .flat_map(|package| {
                package
                    .manifest
                    .contributes
                    .decode_lossy::<MenuContributionPoint>()
                    .into_iter()
                    .filter_map(|item| {
                        find_command(&package.manifest.id, &item.command).map(|command| {
                            ContributedMenuItem {
                                command,
                                menu: item.menu,
                            }
                        })
                    })
                    .collect::<Vec<_>>()
            })
            .collect();
        let toolbar_items: Vec<ContributedToolbarItem> = packages
            .iter()
            .flat_map(|package| {
                package
                    .manifest
                    .contributes
                    .decode_lossy::<ToolbarContributionPoint>()
                    .into_iter()
                    .filter_map(|item| {
                        find_command(&package.manifest.id, &item.command).map(|command| {
                            ContributedToolbarItem {
                                command,
                                icon: item.icon,
                            }
                        })
                    })
                    .collect::<Vec<_>>()
            })
            .collect();
        let document_views: Vec<ContributedDocumentView> = packages
            .iter()
            .flat_map(|package| {
                package
                    .manifest
                    .contributes
                    .decode_lossy::<DocumentViewContributionPoint>()
                    .into_iter()
                    .map(|contribution| {
                        ContributedDocumentView::new(&package.manifest.id, &contribution)
                    })
                    .collect::<Vec<_>>()
            })
            .collect();

        WorkbenchCatalog {
            commands,
            panels,
            menu_items,
            toolbar_items,
            document_views,
        }
    }

    pub fn command(&self, plugin_id: &str, name: &str) -> Option<&ContributedCommand> {
        self.commands
            .iter()
            .find(|command| command.plugin_id == plugin_id && command.name == name)
    }

    pub fn panel(&self, id: &str) -> Option<&ContributedPanel> {
        self.panels.iter().find(|panel| panel.id == id)
    }

    /// The panel that shows a host view, such as the agent conversation.
    pub fn panel_for_view(&self, view: &WorkbenchView) -> Option<&ContributedPanel> {
        self.panels
            .iter()
            .find(|panel| panel.content == ContributedPanelContent::View(view.clone()))
    }

    /// The views a document at `path` can be shown in besides its text.
    pub fn document_views_for_path(&self, path: &str) -> Vec<&ContributedDocumentView> {
        let extension = Path::new(path)
            .extension()
            .and_then(|value| value.to_str())
            .map(str::to_lowercase)
            .unwrap_or_default();
        if extension.is_empty() {
            return Vec::new();
        }
        self.document_views
            .iter()
            .filter(|view| view.extensions.iter().any(|value| *value == extension))
            .collect()
    }

    pub(crate) fn command_ids(&self, plugin_id: &str) -> BTreeSet<String> {
        self.commands
            .iter()
            .filter(|command| command.plugin_id == plugin_id)
            .map(|command| command.name.clone())
            .collect()
    }

    pub(crate) fn panel_ids(&self, plugin_id: &str) -> BTreeSet<String> {
        self.panels
            .iter()
            .filter(|panel| panel.plugin_id == plugin_id)
            .map(|panel| panel.id.clone())
            .collect()
    }
}
