//! Text a package adds to an agent's context.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/AI/Context.swift`.
//! Only agents that list the source receive it; the host bounds its size and
//! sends it with the request.

use serde::{Deserialize, Serialize};

use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_contract::{PluginContract, PluginInputField, PluginInputType};
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::contribution::registry::{ContributionPointSpec, ContributionValidation};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AIContextContribution {
    /// Unique among enabled packages; agents name it in their `context`.
    pub id: String,
    pub title: String,
    /// `func(input: record { workspace: string, selection: string }) -> string`,
    /// or a step-protocol entry point that serves the `context` operation.
    pub entry_point: String,
    /// Longer text is cut to this many UTF-8 bytes; 4 KiB when absent.
    #[serde(default)]
    pub max_bytes: Option<i64>,
}

impl AIContextContribution {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        entry_point: impl Into<String>,
    ) -> Self {
        AIContextContribution {
            id: id.into(),
            title: title.into(),
            entry_point: entry_point.into(),
            max_bytes: None,
        }
    }

    pub fn byte_limit(&self) -> i64 {
        self.max_bytes.unwrap_or(4 * 1_024)
    }
}

pub enum AIContextContributionPoint {}

impl ContributionPointSpec for AIContextContributionPoint {
    type Descriptor = AIContextContribution;

    const ID: &'static str = "cove.ai.context/v1";

    fn validate(
        context: &AIContextContribution,
        _host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        let max_bytes_ok = context
            .max_bytes
            .is_none_or(|value| (1..=16 * 1_024).contains(&value));
        if !(ContributionValidation::identifier(&context.id)
            && ContributionValidation::title(&context.title)
            && ContributionValidation::identifier(&context.entry_point)
            && max_bytes_ok)
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }

    /// A context entry point is either a plain call, or a step-protocol entry
    /// point whose commands the editor runs under the package's process
    /// permission.
    fn validate_runtime(
        context: &AIContextContribution,
        contract: Option<&PluginContract>,
    ) -> Result<(), PluginManifestValidationError> {
        let input_type = contract.and_then(|contract| {
            contract
                .capability_inputs
                .iter()
                .find(|input| input.name == context.entry_point)
                .map(|input| input.input_type.clone())
        });
        let matches = input_type.as_ref() == Some(&ai_context_input_type())
            || input_type.as_ref()
                == Some(&crate::contribution::processes::inputs::step_input_type());
        if !matches {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}

/// `record { content: string, selection: string }`: what the window centers on
/// and the selected scene references as a JSON array.
pub fn ai_context_input_type() -> PluginInputType {
    PluginInputType::Record(vec![
        PluginInputField::new("content", PluginInputType::String),
        PluginInputField::new("selection", PluginInputType::String),
    ])
}
