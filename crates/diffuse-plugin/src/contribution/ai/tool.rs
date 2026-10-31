//! Offers one of the package's capabilities to the model.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/AI/Tool.swift`.
//! A capability no tool names stays with the editor. Calls still go through the
//! capability's permissions, drafts and approvals.

use serde::{Deserialize, Serialize};

use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_contract::PluginContract;
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::contribution::registry::{ContributionPointSpec, ContributionValidation};
use crate::pattern::{grapheme_count, lower_capability};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AIToolContribution {
    /// The capability in `capabilities.json`.
    pub entry_point: String,
    pub title: String,
    /// What the model reads when deciding whether to call it.
    pub description: String,
}

impl AIToolContribution {
    pub fn new(
        entry_point: impl Into<String>,
        title: impl Into<String>,
        description: impl Into<String>,
    ) -> Self {
        AIToolContribution {
            entry_point: entry_point.into(),
            title: title.into(),
            description: description.into(),
        }
    }
}

pub enum AIToolContributionPoint {}

impl ContributionPointSpec for AIToolContributionPoint {
    type Descriptor = AIToolContribution;

    const ID: &'static str = "cove.ai.tool/v1";

    fn validate(
        tool: &AIToolContribution,
        host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        if !(lower_capability(&tool.entry_point, 1, 128)
            && tool.entry_point != "components"
            && !host.entry_points().contains(&tool.entry_point)
            && ContributionValidation::title(&tool.title)
            && !tool.description.is_empty()
            && grapheme_count(&tool.description) <= 1_024)
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }

    fn validate_runtime(
        tool: &AIToolContribution,
        contract: Option<&PluginContract>,
    ) -> Result<(), PluginManifestValidationError> {
        let matches = contract.is_some_and(|contract| {
            contract
                .capability_inputs
                .iter()
                .any(|input| input.name == tool.entry_point)
        });
        if !matches {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}
