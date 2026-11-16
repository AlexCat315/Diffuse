//! `Editor/Sources/EditorCore/Application/AI/AgentTasks.swift`
//!
//! EditorApplication helpers for agent tasks: `updateAgentTask`,
//! `validateAgentTaskTarget`, `makeAgentWorkflowScope`, `beginAgentSceneDocument`
//! and `cancelAgentTask`.

use std::collections::BTreeSet;

use diffuse_ai::session::session_workflow_scope::{SessionAgentContext, SessionWorkflowScope};
use diffuse_capability::capability_contract::CapabilitySourceKind;

use crate::ai::chat::editor_agent_task_service::{EditorAgentTaskPhase, EditorAgentTaskTarget};
use crate::ai::editor_project_tools::EditorProjectToolError;
use crate::application::editor_application::EditorApplication;
use crate::state::editor_reducer::EditorAction;

impl EditorApplication {
    /// `updateAgentTask(_:summary:)` — advance the active task and publish the
    /// refreshed task list to the store.
    pub(crate) fn update_agent_task(&self, phase: EditorAgentTaskPhase, summary: impl Into<String>) {
        self.agent_task_service.borrow_mut().transition(phase, summary);
        let tasks = self.agent_task_service.borrow().tasks().to_vec();
        self.store.dispatch(EditorAction::SetAgentTasks(tasks));
    }

    /// `validateAgentTaskTarget(_:)` — rejects a task whose target scene no longer
    /// matches the live document, or while the simulation is running.
    pub(crate) fn validate_agent_task_target(
        &self,
        target: &EditorAgentTaskTarget,
    ) -> Result<(), EditorProjectToolError> {
        if !self.is_scene_authoring_enabled() {
            return Err(EditorProjectToolError::new(
                "Stop simulation before applying an authoring task.",
            ));
        }
        if !target.matches(&self.store.state().document.identity, self.store.scene_revision()) {
            return Err(EditorProjectToolError::new(
                "The task's scene changed. Submit a new task against the current version.",
            ));
        }
        Ok(())
    }

    /// `makeAgentWorkflowScope(target:)` — assembles the capability/project-tool
    /// allow-list and the agent's context for a task against `target`.
    pub(crate) fn make_agent_workflow_scope(&self, target: &EditorAgentTaskTarget) -> SessionWorkflowScope {
        let profile = target.content.clone().profile();
        let catalog = self.agent_catalog();
        let agent = catalog.agent(&self.store.ai_settings().agent_id);
        let plugin_capability_ids: BTreeSet<String> = self
            .plugin_capability_executor
            .borrow()
            .as_ref()
            .map(|executor| {
                executor
                    .registry
                    .all_verbs()
                    .into_iter()
                    .filter(|verb| {
                        executor
                            .registry
                            .descriptor(verb)
                            .map(|descriptor| descriptor.source.kind == CapabilitySourceKind::Plugin)
                            .unwrap_or(false)
                    })
                    .collect()
            })
            .unwrap_or_default();
        let base: BTreeSet<String> = agent
            .and_then(|descriptor| descriptor.tools.clone())
            .unwrap_or_else(|| profile.capability_ids());
        let capability_ids: BTreeSet<String> = base.union(&plugin_capability_ids).cloned().collect();
        let agent_context = SessionAgentContext::new(
            agent.and_then(|descriptor| descriptor.instructions.clone()),
            agent.and_then(|descriptor| descriptor.host_sources()),
            Vec::new(),
        );
        let mut scope = SessionWorkflowScope::new();
        scope.allowed_capability_ids = Some(capability_ids);
        scope.allowed_project_tool_names = Some(profile.project_tool_names());
        scope.agent = agent_context;
        scope
    }
}
