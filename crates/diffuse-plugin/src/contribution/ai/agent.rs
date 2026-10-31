//! Agent profile contributions.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/AI/Agent.swift`.
//! An agent profile is configuration only; the host runs the session, the tools
//! and every approval.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::contract::host_permissions::PluginHostPermissions;
use crate::contract::plugin_manifest::PluginManifestValidationError;
use crate::contribution::registry::{ContributionPointSpec, ContributionValidation};
use crate::pattern::{grapheme_count, lower_capability};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelPolicy {
    /// Used when the selected provider offers it and the user chose no model.
    #[serde(default)]
    pub preferred: Option<String>,
    /// Caps the provider model's own output limit.
    #[serde(default)]
    pub max_output_tokens: Option<i64>,
}

impl ModelPolicy {
    pub fn new() -> Self {
        ModelPolicy::default()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentContribution {
    pub id: String,
    pub title: String,
    /// Added to the host's own instructions, never replacing them.
    #[serde(default)]
    pub instructions: Option<String>,
    #[serde(default)]
    pub model: Option<ModelPolicy>,
    /// Tool names the agent may call: host tools, capability IDs and package
    /// tools. Absent means every tool the workspace allows.
    #[serde(default)]
    pub tools: Option<Vec<String>>,
    /// Context the agent sees: host sources (`scene`, `selection`, `edits`,
    /// `memory`, `transactions`, `workflow`, `assets`) and `cove.ai.context/v1`
    /// IDs. Absent means every host source and no package context.
    #[serde(default)]
    pub context: Option<Vec<String>>,
    /// False keeps writes on review even when the user turned automatic approval
    /// on.
    #[serde(default)]
    pub can_auto_approve: Option<bool>,
    /// A `cove.ai.harness/v1` that runs the agent's turns; the host's loop when
    /// absent.
    #[serde(default)]
    pub harness: Option<String>,
}

impl AgentContribution {
    pub fn new(id: impl Into<String>, title: impl Into<String>) -> Self {
        AgentContribution {
            id: id.into(),
            title: title.into(),
            instructions: None,
            model: None,
            tools: None,
            context: None,
            can_auto_approve: None,
            harness: None,
        }
    }
}

pub enum AgentContributionPoint {}

impl ContributionPointSpec for AgentContributionPoint {
    type Descriptor = AgentContribution;

    const ID: &'static str = "cove.ai.agent/v1";

    fn validate(
        agent: &AgentContribution,
        _host: &PluginHostPermissions,
    ) -> Result<(), PluginManifestValidationError> {
        let instructions_ok = agent.instructions.as_ref().is_none_or(|instructions| {
            !instructions.is_empty() && grapheme_count(instructions) <= 8_000
        });
        let preferred_ok = agent
            .model
            .as_ref()
            .and_then(|model| model.preferred.as_ref())
            .is_none_or(|preferred| !preferred.is_empty() && grapheme_count(preferred) <= 80);
        let tokens_ok = agent
            .model
            .as_ref()
            .and_then(|model| model.max_output_tokens)
            .is_none_or(|tokens| tokens > 0);
        let tools_ok = agent.tools.as_ref().is_none_or(|tools| {
            let unique: BTreeSet<&String> = tools.iter().collect();
            tools.len() <= 256
                && unique.len() == tools.len()
                && tools.iter().all(|tool| lower_capability(tool, 1, 128))
        });
        let context_ok = agent.context.as_ref().is_none_or(|sources| {
            let unique: BTreeSet<&String> = sources.iter().collect();
            sources.len() <= 32
                && unique.len() == sources.len()
                && sources
                    .iter()
                    .all(|source| ContributionValidation::identifier(source))
        });
        let harness_ok = agent
            .harness
            .as_ref()
            .is_none_or(|harness| ContributionValidation::identifier(harness));
        if !(ContributionValidation::identifier(&agent.id)
            && ContributionValidation::title(&agent.title)
            && instructions_ok
            && preferred_ok
            && tokens_ok
            && tools_ok
            && context_ok
            && harness_ok)
        {
            return Err(PluginManifestValidationError::InvalidContribution(
                Self::ID.to_string(),
            ));
        }
        Ok(())
    }
}
