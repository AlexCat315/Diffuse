//! `Editor/Sources/EditorCore/Application/AI/AIRequests.swift`
//!
//! EditorApplication helpers that translate capability invocation results into
//! store updates and manage the in-flight agent request lifecycle. The larger
//! request pipeline (`submitNaturalLanguageIntent`, `submitPlanTransaction`, …)
//! is ported alongside the session wiring.

use diffuse_ai::planning::proposal::Proposal;
use diffuse_intent::intent_runtime_coordinator::{CapabilityInvocationDisposition, CapabilityInvocationResult};

use crate::application::editor_application::EditorApplication;
use crate::state::editor_reducer::EditorAction;

impl EditorApplication {
    /// `updateSelection(for:applied:)` — selects the authored entity after an
    /// applied plan, or the first confirmation target otherwise. Swift reads
    /// `proposal.plan.scene`, which has no Rust equivalent on `SceneEditPlan`,
    /// so the confirmation-target set drives selection in both branches.
    pub(crate) fn update_selection(&self, _applied: bool) {
        let id = self
            .agent_execution
            .borrow()
            .confirmation_target_entity_ids
            .iter()
            .next()
            .copied();
        self.store.dispatch(EditorAction::SetSelectedEntity(id));
    }

    /// `applyInvocationResult(_:proposal:)` — folds a capability invocation
    /// result into the agent-execution state and the store.
    pub(crate) fn apply_invocation_result(&self, result: &CapabilityInvocationResult, proposal: &Proposal) {
        if let Some(apply_result) = &result.apply_result {
            let mut exec = self.agent_execution.borrow_mut();
            for id in &apply_result.created_entity_ids {
                exec.confirmation_target_entity_ids.insert(*id);
            }
            for id in &apply_result.deleted_entity_ids {
                exec.confirmation_target_entity_ids.remove(id);
            }
        }
        let is_confirmed = matches!(result.disposition, CapabilityInvocationDisposition::Applied);
        if is_confirmed {
            let mut exec = self.agent_execution.borrow_mut();
            exec.confidence = proposal.confidence;
            exec.semantic_intent = Some(proposal.semantic_intent.clone());
            exec.approval_policy = Some(proposal.approval_policy.clone());
        }
        self.update_selection(is_confirmed);
        match &result.confirmation_request {
            Some(request) => self
                .store
                .dispatch(EditorAction::SetPendingConfirmationRequest(Some(request.clone()))),
            None => self
                .store
                .dispatch(EditorAction::SetPendingConfirmationRequest(None)),
        }
    }

    /// `skipPendingConfirmation()` — drops the pending confirmation and resets the
    /// in-flight request task. (A detached `JoinHandle` cannot be force-cancelled
    /// from the main thread; the worker exits cooperatively.)
    pub(crate) fn skip_pending_confirmation(&self) {
        self.store
            .dispatch(EditorAction::SetPendingConfirmationRequest(None));
        self.store.dispatch(EditorAction::SetAgentCanvas(None));
        let mut exec = self.agent_execution.borrow_mut();
        exec.assistant_message_id = None;
        exec.proposal = None;
        exec.request_task.take();
    }
}
