//! `Editor/Sources/EditorCore/Contributions/Agents.swift`.

use std::collections::BTreeSet;

use diffuse_ai::session::session_workflow_scope::SessionContextSource;
use diffuse_plugin::contract::plugin_package::ValidatedPluginPackage;
use diffuse_plugin::contribution::ai::agent::{AgentContribution, AgentContributionPoint};

/// One enabled agent contribution, narrowed to what the session needs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentDescriptor {
    pub plugin_id: String,
    pub id: String,
    pub title: String,
    pub instructions: Option<String>,
    pub preferred_model: Option<String>,
    pub max_output_tokens: Option<i64>,
    /// `None` means every tool the workspace allows.
    pub tools: Option<BTreeSet<String>>,
    /// `None` means every host source and no package context.
    pub context: Option<BTreeSet<String>>,
    pub can_auto_approve: bool,
    /// The `cove.ai.harness/v1` running this agent's turns; `None` for the built-in loop.
    pub harness: Option<String>,
}

impl AgentDescriptor {
    pub fn new(plugin_id: impl Into<String>, contribution: &AgentContribution) -> Self {
        AgentDescriptor {
            plugin_id: plugin_id.into(),
            id: contribution.id.clone(),
            title: contribution.title.clone(),
            instructions: contribution.instructions.clone(),
            preferred_model: contribution
                .model
                .as_ref()
                .and_then(|model| model.preferred.clone()),
            max_output_tokens: contribution
                .model
                .as_ref()
                .and_then(|model| model.max_output_tokens),
            tools: contribution
                .tools
                .as_ref()
                .map(|tools| tools.iter().cloned().collect()),
            context: contribution
                .context
                .as_ref()
                .map(|context| context.iter().cloned().collect()),
            can_auto_approve: contribution.can_auto_approve.unwrap_or(true),
            harness: contribution.harness.clone(),
        }
    }

    /// The host sources the agent keeps; a name that is no host source is a package context.
    pub(crate) fn host_sources(&self) -> Option<BTreeSet<SessionContextSource>> {
        self.context.as_ref().map(|context| {
            context
                .iter()
                .filter_map(|name| SessionContextSource::from_raw_value(name))
                .collect()
        })
    }

    pub(crate) fn package_contexts(&self) -> BTreeSet<String> {
        self.context
            .iter()
            .flatten()
            .filter(|name| SessionContextSource::from_raw_value(name).is_none())
            .cloned()
            .collect()
    }
}

/// Enabled agents for one editor session. Empty means the editor has no
/// assistant surface at all: no panel, no command, no status entry.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AgentCatalog {
    pub agents: Vec<AgentDescriptor>,
}

impl AgentCatalog {
    /// Swift's `static let empty`.
    pub fn empty() -> Self {
        AgentCatalog { agents: Vec::new() }
    }

    /// Swift's `agents: [AgentDescriptor] = []` default.
    pub fn with_default_agents() -> Self {
        Self::empty()
    }

    pub fn new(agents: Vec<AgentDescriptor>) -> Self {
        AgentCatalog { agents }
    }

    pub fn from_packages(mut packages: Vec<ValidatedPluginPackage>) -> Self {
        packages.sort_by(|left, right| left.manifest.id.cmp(&right.manifest.id));
        let agents = packages
            .into_iter()
            .flat_map(|package| {
                package
                    .manifest
                    .contributes
                    .decode::<AgentContributionPoint>()
                    .unwrap_or_default()
                    .into_iter()
                    .map(move |contribution| {
                        AgentDescriptor::new(package.manifest.id.clone(), &contribution)
                    })
            })
            .collect();
        AgentCatalog { agents }
    }

    pub fn is_empty(&self) -> bool {
        self.agents.is_empty()
    }

    pub fn is_enabled(&self) -> bool {
        !self.agents.is_empty()
    }

    /// The chosen agent, or the first when the choice is empty or gone.
    pub fn agent(&self, id: &str) -> Option<&AgentDescriptor> {
        self.agents
            .iter()
            .find(|agent| agent.id == id)
            .or_else(|| self.agents.first())
    }
}
