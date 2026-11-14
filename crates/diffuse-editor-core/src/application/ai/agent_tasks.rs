//! `Editor/Sources/EditorCore/Application/AI/AgentTasks.swift`
//!
//! EditorApplication helpers for agent tasks: `updateAgentTask`,
//! `validateAgentTaskTarget`, `makeAgentWorkflowScope`, `beginAgentSceneDocument`
//! and `cancelAgentTask`.

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
}
