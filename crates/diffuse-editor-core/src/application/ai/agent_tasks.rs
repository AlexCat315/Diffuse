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
    /// allow-list, the workflow context and the agent's instructions for a task.
    pub(crate) fn make_agent_workflow_scope(&self, target: &EditorAgentTaskTarget) -> SessionWorkflowScope {
        let profile = target.content.clone().profile();
        let catalog = self.agent_catalog();
        let agent = catalog.agent(&self.store.ai_settings().agent_id);
        let script_entries = self.scene.script_catalog_entries.borrow().clone();
        let context = Some(Self::workflow_context(target.content, &script_entries));
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
        // The profile's own capabilities, joined with every plugin verb.
        let capabilities: BTreeSet<String> = profile
            .capability_ids()
            .union(&plugin_capability_ids)
            .cloned()
            .collect();
        // An agent can narrow what the workspace allows, never widen it; `respond`
        // stays so a turn can always finish.
        let allowed_capability_ids = agent
            .and_then(|descriptor| descriptor.tools.clone())
            .map(|tools| capabilities.intersection(&tools).cloned().collect())
            .unwrap_or(capabilities);
        let mut respond = BTreeSet::from(["respond".to_string()]);
        let allowed_project_tool_names = agent
            .and_then(|descriptor| descriptor.tools.clone())
            .map(|tools| {
                respond.extend(tools);
                profile
                    .project_tool_names()
                    .intersection(&respond)
                    .cloned()
                    .collect::<BTreeSet<String>>()
            })
            .unwrap_or_else(|| profile.project_tool_names());
        let agent_context = SessionAgentContext::new(
            agent.and_then(|descriptor| descriptor.instructions.clone()),
            agent.and_then(|descriptor| descriptor.host_sources()),
            Vec::new(),
        );
        let selected_entity_refs = Some(
            target
                .selected_entity_ids
                .iter()
                .map(|id| format!("scene:{id}"))
                .collect::<Vec<_>>(),
        );
        let mut scope = SessionWorkflowScope::new();
        scope.context = context;
        scope.allowed_capability_ids = Some(allowed_capability_ids);
        scope.allowed_project_tool_names = Some(allowed_project_tool_names);
        scope.agent = agent_context;
        scope.selected_entity_refs = selected_entity_refs;
        scope
    }

    /// `beginAgentSceneDocument()` — a new document invalidates requests even
    /// when the replacement scene reuses the old numeric revision.
    pub(crate) fn begin_agent_scene_document(&self) {
        if self.store.pending_confirmation_request().is_some() {
            self.skip_pending_confirmation();
        }
        self.cancel_active_ai_request();
        self.agent_execution.borrow_mut().assistant_message_id = None;
        self.agent_execution
            .borrow_mut()
            .confirmation_target_entity_ids
            .clear();
        self.store
            .dispatch(EditorAction::SetPendingConfirmationRequest(None));
        self.store.dispatch(EditorAction::BeginSceneDocument);
    }

    /// `cancelAgentTask()` — stops the in-flight request and cancels the
    /// session's active run.
    pub(crate) fn cancel_agent_task(&self) {
        if self.agent_execution.borrow().request_id.is_none() {
            return;
        }
        self.cancel_active_ai_request();
        if let Some(session) = self.session.borrow().clone() {
            session.cancel_active_run();
        }
    }

}
