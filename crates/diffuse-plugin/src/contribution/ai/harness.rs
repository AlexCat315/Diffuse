//! A turn loop a package offers to agents.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/AI/Harness.swift`.
//! Its entry point says what the session does next; the host calls the model,
//! runs tools and keeps every approval.

use serde::{Deserialize, Serialize};

use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_contract::{PluginContract, PluginInputField, PluginInputType};
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::contribution::registry::{ContributionPointSpec, ContributionValidation};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AIHarnessContribution {
    /// Unique among enabled packages; agents name it in `harness`.
    pub id: String,
    pub title: String,
    /// `func(input: record { turn: string }) -> string`.
    pub entry_point: String,
}

impl AIHarnessContribution {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        entry_point: impl Into<String>,
    ) -> Self {
        AIHarnessContribution {
            id: id.into(),
            title: title.into(),
            entry_point: entry_point.into(),
        }
    }
}

pub enum AIHarnessContributionPoint {}

impl ContributionPointSpec for AIHarnessContributionPoint {
    type Descriptor = AIHarnessContribution;

    const ID: &'static str = "cove.ai.harness/v1";

    fn validate(
        harness: &AIHarnessContribution,
        _host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        if !(ContributionValidation::identifier(&harness.id)
            && ContributionValidation::title(&harness.title)
            && ContributionValidation::identifier(&harness.entry_point))
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }

    fn validate_runtime(
        harness: &AIHarnessContribution,
        contract: Option<&PluginContract>,
    ) -> Result<(), PluginManifestValidationError> {
        let matches = contract
            .and_then(|contract| {
                contract
                    .capability_inputs
                    .iter()
                    .find(|input| input.name == harness.entry_point)
            })
            .is_some_and(|input| input.input_type == harness_input_type());
        if !matches {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}

/// `record { turn: string }`: the step's input as JSON.
pub fn harness_input_type() -> PluginInputType {
    PluginInputType::Record(vec![PluginInputField::new("turn", PluginInputType::String)])
}
