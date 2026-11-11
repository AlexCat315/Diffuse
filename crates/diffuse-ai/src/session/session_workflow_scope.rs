//! Ported from `Engine/Sources/AIRuntime/Session/SessionWorkflowScope.swift`.

use std::collections::BTreeSet;

use diffuse_capability::capability_contract::CapabilityExposurePolicy;

use crate::context::workflow_context::WorkflowContext;

/// Captured for a request. Provider transports and tool discovery use the same
/// authority set; selection stays bound while the visible shell changes.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SessionWorkflowScope {
    pub context: Option<WorkflowContext>,
    pub allowed_capability_ids: Option<BTreeSet<String>>,
    pub allowed_project_tool_names: Option<BTreeSet<String>>,
    pub selected_entity_refs: Option<Vec<String>>,
    pub agent: SessionAgentContext,
}

impl SessionWorkflowScope {
    pub fn new() -> Self {
        Self::default()
    }

    /// `SessionWorkflowScope { ... }` with the Swift inout configuration closure.
    pub fn with_configure(configure: impl FnOnce(&mut Self)) -> Self {
        let mut scope = Self::default();
        configure(&mut scope);
        scope
    }

    pub(crate) fn restricting(
        &self,
        policy: &CapabilityExposurePolicy,
    ) -> CapabilityExposurePolicy {
        let mut result = policy.clone();
        if let Some(ids) = &self.allowed_capability_ids {
            result.allowed_capability_ids = Some(match &policy.allowed_capability_ids {
                Some(existing) => existing.intersection(ids).cloned().collect(),
                None => ids.clone(),
            });
        }
        result
    }
}

/// A host source of model context an agent may leave out.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum SessionContextSource {
    Scene,
    Selection,
    Edits,
    Memory,
    Transactions,
    Workflow,
    Assets,
}

impl SessionContextSource {
    pub const ALL: [SessionContextSource; 7] = [
        SessionContextSource::Scene,
        SessionContextSource::Selection,
        SessionContextSource::Edits,
        SessionContextSource::Memory,
        SessionContextSource::Transactions,
        SessionContextSource::Workflow,
        SessionContextSource::Assets,
    ];

    /// Swift's `String` raw value.
    pub const fn raw_value(self) -> &'static str {
        match self {
            SessionContextSource::Scene => "scene",
            SessionContextSource::Selection => "selection",
            SessionContextSource::Edits => "edits",
            SessionContextSource::Memory => "memory",
            SessionContextSource::Transactions => "transactions",
            SessionContextSource::Workflow => "workflow",
            SessionContextSource::Assets => "assets",
        }
    }

    /// Swift's `init?(rawValue:)`.
    pub fn from_raw_value(value: &str) -> Option<SessionContextSource> {
        Self::ALL
            .into_iter()
            .find(|source| source.raw_value() == value)
    }
}

/// Text from outside the session, such as a plugin's context, sent with the request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionContextSection {
    pub title: String,
    pub text: String,
}

impl SessionContextSection {
    pub fn new(title: impl Into<String>, text: impl Into<String>) -> Self {
        Self {
            title: title.into(),
            text: text.into(),
        }
    }
}

/// What the active agent adds to and keeps out of a request. The host's own
/// instructions and rules always remain.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SessionAgentContext {
    pub instructions: Option<String>,
    /// The host sources the agent sees; `None` means all of them.
    pub sources: Option<BTreeSet<SessionContextSource>>,
    pub sections: Vec<SessionContextSection>,
}

impl SessionAgentContext {
    pub fn new(
        instructions: Option<String>,
        sources: Option<BTreeSet<SessionContextSource>>,
        sections: Vec<SessionContextSection>,
    ) -> Self {
        Self {
            instructions,
            sources,
            sections,
        }
    }

    /// `SessionAgentContext()` — no instructions, every source, no sections.
    pub fn with_defaults() -> Self {
        Self::default()
    }

    pub fn includes(&self, source: SessionContextSource) -> bool {
        match &self.sources {
            Some(sources) => sources.contains(&source),
            None => true,
        }
    }
}
