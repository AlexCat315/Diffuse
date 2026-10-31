//! Workbench panel declarations.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/Workbench/Panel.swift`.
//! The host owns the panel's frame, tab, focus and layout; the package chooses
//! what fills it, either a view the host provides or a component tree its entry
//! point returns.

use serde::{Deserialize, Serialize};

use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_contract::PluginContract;
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::contribution::registry::{ContributionPointSpec, ContributionValidation};
use crate::contribution::workbench::view::view_input_type;
use crate::pattern::{icon, lower_dot};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PanelContent {
    /// A view the host provides, such as `agent`.
    View(String),
    /// A capability that serves the panel through the view protocol.
    EntryPoint(String),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PanelContribution {
    /// Unique among enabled packages; layouts persist it.
    pub id: String,
    pub title: String,
    /// `leading`, `center`, `trailing` or `bottom`; trailing when absent.
    #[serde(default)]
    pub slot: Option<String>,
    /// The name of one of the host's panel icons.
    #[serde(default)]
    pub icon: Option<String>,
    #[serde(default)]
    pub view: Option<String>,
    #[serde(default)]
    pub entry_point: Option<String>,
    /// Registers a top-level mode rendered by this panel's own entry point.
    #[serde(default)]
    pub surface: Option<String>,
    /// Mounts a region in another contributed mode, e.g. `studio.ai.assistant`.
    #[serde(default)]
    pub in_surface: Option<String>,
}

impl PanelContribution {
    pub fn new(id: impl Into<String>, title: impl Into<String>, content: PanelContent) -> Self {
        let mut panel = PanelContribution {
            id: id.into(),
            title: title.into(),
            slot: None,
            icon: None,
            view: None,
            entry_point: None,
            surface: None,
            in_surface: None,
        };
        match content {
            PanelContent::View(view) => panel.view = Some(view),
            PanelContent::EntryPoint(entry_point) => panel.entry_point = Some(entry_point),
        }
        panel
    }

    /// Validation guarantees exactly one of `view` and `entry_point`.
    pub fn content(&self) -> PanelContent {
        if let Some(entry_point) = &self.entry_point {
            return PanelContent::EntryPoint(entry_point.clone());
        }
        PanelContent::View(self.view.clone().unwrap_or_default())
    }
}

pub enum PanelContributionPoint {}

impl ContributionPointSpec for PanelContributionPoint {
    type Descriptor = PanelContribution;

    const ID: &'static str = "cove.ui.panel/v1";

    fn validate(
        panel: &PanelContribution,
        _host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        if !(ContributionValidation::identifier(&panel.id)
            && ContributionValidation::title(&panel.title)
            && panel.slot.as_ref().is_none_or(|slot| {
                ["leading", "center", "trailing", "bottom"].contains(&slot.as_str())
            })
            && panel.icon.as_ref().is_none_or(|value| icon(value, 1, 64))
            // `panel.view == nil` — the host resolves the entry point instead.
            && panel.view.is_none()
            && panel
                .entry_point
                .as_ref()
                .map(|entry_point| ContributionValidation::identifier(entry_point))
                == Some(true))
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        let surface_ok = panel.surface.as_ref().is_none_or(|surface| {
            ContributionValidation::identifier(surface) && panel.entry_point.is_some()
        });
        if !surface_ok {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        if let Some(target) = &panel.in_surface {
            let slot = panel.slot.clone().unwrap_or_else(|| "trailing".to_string());
            if !(panel.surface.is_none()
                && ["leading", "trailing", "bottom"].contains(&slot.as_str())
                && lower_dot(target, 3, 128))
            {
                return Err(PluginManifestValidationError::InvalidContribution(
                    Self::ID.to_string(),
                ));
            }
        }
        Ok(())
    }

    fn validate_runtime(
        panel: &PanelContribution,
        contract: Option<&PluginContract>,
    ) -> Result<(), PluginManifestValidationError> {
        let PanelContent::EntryPoint(entry_point) = panel.content() else {
            return Ok(());
        };
        let matches = contract
            .and_then(|contract| {
                contract
                    .capability_inputs
                    .iter()
                    .find(|input| input.name == entry_point)
            })
            .is_some_and(|input| input.input_type == view_input_type());
        if !matches {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}
