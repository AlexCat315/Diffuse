//! Menu and toolbar placements for a package's own commands.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/Workbench/Placement.swift`.

use std::collections::BTreeSet;
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};

use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::contribution::registry::{ContributionPointSpec, ContributionValidation};
use crate::pattern::icon;

/// Puts one of the package's own commands into a host menu, after the host's
/// items.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MenuContribution {
    /// A `cove.command/v1` identifier of the same package.
    pub command: String,
    /// `file`, `edit`, `select`, `world`, `view`, `agent`, `run`, `window` or
    /// `help`.
    pub menu: String,
}

impl MenuContribution {
    pub fn new(command: impl Into<String>, menu: impl Into<String>) -> Self {
        MenuContribution {
            command: command.into(),
            menu: menu.into(),
        }
    }

    pub fn menus() -> &'static BTreeSet<&'static str> {
        static MENUS: LazyLock<BTreeSet<&'static str>> = LazyLock::new(|| {
            [
                "file", "edit", "select", "world", "view", "agent", "run", "window", "help",
            ]
            .into_iter()
            .collect()
        });
        &MENUS
    }
}

pub enum MenuContributionPoint {}

impl ContributionPointSpec for MenuContributionPoint {
    type Descriptor = MenuContribution;

    const ID: &'static str = "cove.ui.menu/v1";

    fn validate(
        item: &MenuContribution,
        _host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        if !(ContributionValidation::identifier(&item.command)
            && MenuContribution::menus().contains(item.menu.as_str()))
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}

/// Puts one of the package's own commands on the title bar as an icon button;
/// the command's title is the tooltip.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolbarContribution {
    /// A `cove.command/v1` identifier of the same package.
    pub command: String,
    /// The name of one of the host's toolbar icons.
    pub icon: String,
}

impl ToolbarContribution {
    pub fn new(command: impl Into<String>, icon: impl Into<String>) -> Self {
        ToolbarContribution {
            command: command.into(),
            icon: icon.into(),
        }
    }
}

pub enum ToolbarContributionPoint {}

impl ContributionPointSpec for ToolbarContributionPoint {
    type Descriptor = ToolbarContribution;

    const ID: &'static str = "cove.ui.toolbar/v1";

    fn validate(
        item: &ToolbarContribution,
        _host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        if !(ContributionValidation::identifier(&item.command) && icon(&item.icon, 1, 64)) {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}
