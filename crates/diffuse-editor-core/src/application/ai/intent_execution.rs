//! `Editor/Sources/EditorCore/Application/AI/IntentExecution.swift`.
//!
//! Direct-intent submission (`submitSpawnEntityIntent` and the selection-based
//! verbs), plus result application: scene write-back, confirmation bookkeeping,
//! chat state, edit log and world-event observation.

use diffuse_ai::session::signal::Signal;
use diffuse_intent::invocation::capability_invocation_planning::CapabilityInvocationContext;
use diffuse_intent::planning::edit::EditAuthorKind;
use diffuse_intent::pipeline::commit_pipeline::CommitEntry;
use diffuse_intent::planning::intent_ir::{
    IntentEvidence, IntentIR, IntentSource, IntentVector3,
};
use diffuse_intent::planning::intent_ir::IntentArgumentValue;
use diffuse_intent::transactions::intent_transaction_builder::IntentTransactionBuildContext;
use diffuse_intent::transactions::transaction_executor::{
    TransactionApplyResult, TransactionExecutionContext,
};
use diffuse_intent::intent_runtime_coordinator::CapabilityInvocationDisposition;
use diffuse_observation::event_envelope::{EventOrigin, EventOriginProcessKind};
use diffuse_scene::entity_id::EntityID;

use crate::ai::chat::ai_chat_message::AIChatAssistantState;
use crate::ai::chat::editor_ai_request_policy::EditorPlanSubmissionError;
use crate::ai::chat::editor_agent_task_service::EditorAgentTaskPhase;
use crate::application::editor_application::EditorApplication;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::PlaybackState;

impl EditorApplication {
    /// `entityID(from:)` — reconstructs an `EntityID` from its packed `UInt64`
    /// (`index` in the low 32 bits, `generation` in the high 32 bits).
    pub(crate) fn entity_id(&self, raw_id: Option<u64>) -> Option<EntityID> {
        raw_id.map(|raw| EntityID::new((raw & 0xFFFF_FFFF) as u32, (raw >> 32) as u32))
    }

    /// `prefix(_:bytes:)` — the longest UTF-8 prefix of `text` within `bytes`
    /// bytes that does not split a scalar.
    pub(crate) fn prefix(text: &str, bytes: usize) -> String {
        if text.len() <= bytes {
            return text.to_string();
        }
        let mut cut = bytes;
        while cut > 0 {
            if std::str::from_utf8(&text.as_bytes()[..cut]).is_ok() {
                return text[..cut].to_string();
            }
            cut -= 1;
        }
        String::new()
    }

    /// `submitSpawnEntityIntent(label:position:)` — empty labels fall back to
    /// "AI Entity".
    pub fn submit_spawn_entity_intent(&self, label: &str, position: [f32; 3]) {
        let trimmed = label.trim();
        let resolved_label = if trimmed.is_empty() {
            "AI Entity".to_string()
        } else {
            trimmed.to_string()
        };
        let mut arguments = std::collections::BTreeMap::new();
        arguments.insert(
            "label".to_string(),
            IntentArgumentValue::String(resolved_label),
        );
        arguments.insert(
            "position".to_string(),
            IntentArgumentValue::Vec3(IntentVector3::new(position[0], position[1], position[2])),
        );
        let mut intent = IntentIR::new("scene.spawn_entity", "Spawn scene entity", IntentSource::Human);
        intent.arguments = arguments;
        self.submit_resolved_intent(&intent);
    }

    /// `submitRenameSelectedEntityIntent(name:)`.
    pub fn submit_rename_selected_entity_intent(&self, name: &str) {
        let Some(selected) = self.store.selected_entity_id() else {
            self.store
                .dispatch(EditorAction::SetAIStatusMessage(Some(
                    "Select an entity before renaming it.".into(),
                )));
            return;
        };
        if self.scene.entity_summary(Some(selected)).is_none() {
            self.store
                .dispatch(EditorAction::SetAIStatusMessage(Some(
                    "Select an entity before renaming it.".into(),
                )));
            return;
        }
        let trimmed = name.trim();
        if trimmed.is_empty() {
            self.store
                .dispatch(EditorAction::SetAIStatusMessage(Some(
                    "Enter a name before renaming the selection.".into(),
                )));
            return;
        }
        let mut arguments = std::collections::BTreeMap::new();
        arguments.insert("name".to_string(), IntentArgumentValue::String(trimmed.to_string()));
        let mut intent = IntentIR::new("scene.set_name", "Rename selected entity", IntentSource::Human);
        intent.target_object_ids = vec![format!("scene:{selected}")];
        intent.arguments = arguments;
        self.submit_resolved_intent(&intent);
    }

    /// `submitDuplicateSelectedEntityIntent()`.
    pub fn submit_duplicate_selected_entity_intent(&self) {
        let Some(selected) = self.store.selected_entity_id() else {
            self.store
                .dispatch(EditorAction::SetAIStatusMessage(Some(
                    "Select an entity before duplicating it.".into(),
                )));
            return;
        };
        if self.scene.entity_summary(Some(selected)).is_none() {
            self.store
                .dispatch(EditorAction::SetAIStatusMessage(Some(
                    "Select an entity before duplicating it.".into(),
                )));
            return;
        }
        let mut intent = IntentIR::new("scene.duplicate_entity", "Duplicate selected entity", IntentSource::Human);
        intent.target_object_ids = vec![format!("scene:{selected}")];
        self.submit_resolved_intent(&intent);
    }

    /// `submitDeleteSelectedEntityIntent()`.
    pub fn submit_delete_selected_entity_intent(&self) {
        let Some(selected) = self.store.selected_entity_id() else {
            self.store
                .dispatch(EditorAction::SetAIStatusMessage(Some(
                    "Select an entity before deleting it.".into(),
                )));
            return;
        };
        if self.scene.entity_summary(Some(selected)).is_none() {
            self.store
                .dispatch(EditorAction::SetAIStatusMessage(Some(
                    "Select an entity before deleting it.".into(),
                )));
            return;
        }
        let mut intent = IntentIR::new("scene.delete_entity", "Delete selected entity", IntentSource::Human);
        intent.target_object_ids = vec![format!("scene:{selected}")];
        self.submit_resolved_intent(&intent);
    }

    /// `submitSetTransformIntent(translation:)`.
    pub fn submit_set_transform_intent(&self, translation: [f32; 3]) {
        let Some(selected) = self.store.selected_entity_id() else {
            self.store
                .dispatch(EditorAction::SetAIStatusMessage(Some(
                    "Select an entity before setting its transform.".into(),
                )));
            return;
        };
        if self.entity_id(Some(selected)).is_none() {
            self.store
                .dispatch(EditorAction::SetAIStatusMessage(Some(
                    "Select an entity before setting its transform.".into(),
                )));
            return;
        }
        let mut arguments = std::collections::BTreeMap::new();
        arguments.insert(
            "translation".to_string(),
            IntentArgumentValue::Vec3(IntentVector3::new(
                translation[0],
                translation[1],
                translation[2],
            )),
        );
        let mut intent = IntentIR::new("scene.set_transform", "Set selected transform", IntentSource::Human);
        intent.target_object_ids = vec![format!("scene:{selected}")];
        intent.arguments = arguments;
        self.submit_resolved_intent(&intent);
    }

    /// `submitResolvedIntent(_:)` — builds and submits the human-entry
    /// transaction; a pending confirmation is surfaced as its policy message.
    fn submit_resolved_intent(&self, intent: &IntentIR) {
        let built = self
            .intent_transaction_builder
            .build_transaction(intent, &self.make_intent_transaction_build_context());
        match built {
            Ok(transaction) => {
                let capability_context = self.make_capability_invocation_context(
                    intent.source,
                    intent.confidence,
                    intent.evidence.clone(),
                );
                if let Err(error) =
                    self.submit_plan_transaction(&transaction, Some(capability_context), CommitEntry::Human)
                {
                    self.handle_plan_submission_error(error.as_ref());
                }
            }
            Err(error) => {
                self.store
                    .dispatch(EditorAction::SetPendingConfirmationRequest(None));
                self.store.dispatch(EditorAction::SetAIWarnings(Vec::new()));
                self.store
                    .dispatch(EditorAction::SetAIStatusMessage(Some(error.to_string())));
            }
        }
    }

    /// Shared failure handling for the submit paths: a pending confirmation
    /// explains itself, everything else clears the review state.
    pub(crate) fn handle_plan_submission_error(&self, error: &(dyn std::error::Error + 'static)) {
        if let Some(plan_error) = error
            .downcast_ref::<EditorPlanSubmissionError>()
            .cloned()
        {
            match plan_error {
                EditorPlanSubmissionError::PendingConfirmation => {
                    self.store.dispatch(EditorAction::SetAIStatusMessage(Some(
                        crate::ai::chat::editor_ai_request_policy::EditorAIRequestPolicy::PENDING_CONFIRMATION_MESSAGE.to_string(),
                    )));
                }
                EditorPlanSubmissionError::LockedEntities(_) => {
                    self.store
                        .dispatch(EditorAction::SetAIStatusMessage(Some(plan_error.to_string())));
                }
            }
            return;
        }
        self.store
            .dispatch(EditorAction::SetPendingConfirmationRequest(None));
        self.store.dispatch(EditorAction::SetAIWarnings(Vec::new()));
        self.store
            .dispatch(EditorAction::SetAIStatusMessage(Some(error.to_string())));
    }

    /// `makeIntentTransactionBuildContext()`.
    fn make_intent_transaction_build_context(&self) -> IntentTransactionBuildContext {
        IntentTransactionBuildContext {
            scene_runtime: self.scene.scene(),
            selected_entity_id: self.store.selected_entity_id(),
            default_spawn_mesh_index: self.default_spawn_mesh_index(),
        }
    }

    /// `makeCapabilityInvocationContext(defaultSource:defaultConfidence:defaultEvidence:)`
    /// — selects the authoring target and wraps the live scene runtime.
    pub(crate) fn make_capability_invocation_context(
        &self,
        default_source: IntentSource,
        default_confidence: f64,
        default_evidence: Vec<IntentEvidence>,
    ) -> CapabilityInvocationContext {
        let selected_entity_id = if default_source == IntentSource::Ai {
            self.agent_task_service
                .borrow()
                .active_task()
                .and_then(|task| task.target.primary_entity_id)
        } else {
            self.store.selected_entity_id()
        };
        let scene_runtime = self.scene.scene();
        CapabilityInvocationContext::from_scene_runtime(
            &scene_runtime,
            selected_entity_id,
            self.store.playback_state() == PlaybackState::Stopped,
            default_source,
            default_confidence,
            default_evidence,
        )
    }

    /// `applyInvocationResult(_:executionContext:)` — writes the executed scene
    /// back, then updates the task, chat, confirmation, edit log and world.
    pub(crate) fn apply_invocation_result(
        &self,
        result: &diffuse_intent::intent_runtime_coordinator::CapabilityInvocationResult,
        execution_context: &mut TransactionExecutionContext,
    ) {
        if let Some(updated_scene) = execution_context.scene_runtime.take() {
            self.scene.set_scene(updated_scene);
            let revision = self.scene.scene().snapshot().revision;
            self.scene.notify_revision_handlers(revision);
        }

        match result.disposition {
            CapabilityInvocationDisposition::Applied => {
                let proposal_summary = self
                    .agent_execution
                    .borrow()
                    .proposal
                    .as_ref()
                    .map(|proposal| proposal.plan.summary.clone());
                if self.agent_execution.borrow().proposal.is_some() {
                    self.update_agent_task(
                        EditorAgentTaskPhase::Applied,
                        proposal_summary.clone().unwrap_or_else(|| "Applied".into()),
                    );
                }
                self.agent_execution
                    .borrow_mut()
                    .confirmation_target_entity_ids
                    .clear();
                self.store
                    .dispatch(EditorAction::SetPendingConfirmationRequest(None));
                self.store
                    .dispatch(EditorAction::SetAIWarnings(result.warnings.clone()));
                self.update_selection_after_apply(result.apply_result.as_ref());
                self.store.dispatch(EditorAction::SetAIStatusMessage(Some(format!(
                    "Applied {}",
                    result.transaction_id
                ))));
                let assistant_message_id =
                    self.agent_execution.borrow().assistant_message_id.clone();
                if let Some(aid) = assistant_message_id {
                    let applied_summary = proposal_summary
                        .as_deref()
                        .filter(|summary| !summary.is_empty())
                        .unwrap_or("Applied");
                    self.store.dispatch(EditorAction::UpdateChatMessage {
                        id: aid,
                        assistant_state: AIChatAssistantState::Applied {
                            summary: applied_summary.to_string(),
                        },
                    });
                    self.agent_execution.borrow_mut().assistant_message_id = None;
                }
                if let Some(apply_result) = &result.apply_result {
                    let mut edit = apply_result.edit.clone();
                    // Enrich provenance with the proposal that generated this edit.
                    let proposal = self.agent_execution.borrow_mut().proposal.take();
                    if let Some(proposal) = proposal {
                        edit.provenance.proposal_id = Some(proposal.id.clone());
                        let accepted_step_ids: Vec<String> = (0..proposal.plan.steps.len())
                            .map(|index| format!("step_{index}"))
                            .collect();
                        if let Some(session) = self.session.borrow().clone() {
                            let signal = Signal::UserCorrection {
                                proposal_id: proposal.id.clone(),
                                accepted_step_ids,
                                rejected_step_ids: Vec::new(),
                            };
                            let _ = session.process(&signal, None);
                        }
                    }
                    if let Err(error) = self.edit_log.append(&edit) {
                        self.log_console(
                            "Failed to record applied edit",
                            crate::state::editor_state::EditorConsoleSeverity::Error,
                            Some(format!("{}: {error}", edit.id)),
                            None,
                            None,
                        );
                    }
                    if !apply_result.world_events.is_empty() {
                        self.observe_world_events(&apply_result.world_events);
                    }
                }
            }
            CapabilityInvocationDisposition::ConfirmationRequested => {
                let proposal_summary = self
                    .agent_execution
                    .borrow()
                    .proposal
                    .as_ref()
                    .map(|proposal| proposal.plan.summary.clone())
                    .unwrap_or_default();
                if self.agent_execution.borrow().proposal.is_some() {
                    self.update_agent_task(EditorAgentTaskPhase::AwaitingReview, proposal_summary);
                }
                self.store
                    .dispatch(EditorAction::SetPendingConfirmationRequest(
                        result.confirmation_request.clone(),
                    ));
                self.store
                    .dispatch(EditorAction::SetAIWarnings(result.warnings.clone()));
                self.store.dispatch(EditorAction::SetAIStatusMessage(Some(format!(
                    "Confirmation required for {}",
                    result.transaction_id
                ))));
                let assistant_message_id =
                    self.agent_execution.borrow().assistant_message_id.clone();
                if let Some(aid) = assistant_message_id {
                    let prompt = result
                        .confirmation_request
                        .as_ref()
                        .and_then(|request| request.questions.first())
                        .map(|question| question.prompt_short.clone())
                        .filter(|prompt| !prompt.is_empty())
                        .unwrap_or_else(|| "Confirmation required".into());
                    self.store.dispatch(EditorAction::UpdateChatMessage {
                        id: aid,
                        assistant_state: AIChatAssistantState::PendingConfirmation {
                            summary: prompt,
                        },
                    });
                }
            }
            CapabilityInvocationDisposition::Discarded => {
                if self.agent_execution.borrow().proposal.is_some() {
                    self.update_agent_task(EditorAgentTaskPhase::Discarded, "Proposal discarded");
                }
                self.agent_execution
                    .borrow_mut()
                    .confirmation_target_entity_ids
                    .clear();
                self.store
                    .dispatch(EditorAction::SetPendingConfirmationRequest(None));
                self.store
                    .dispatch(EditorAction::SetAIWarnings(result.warnings.clone()));
                self.store.dispatch(EditorAction::SetAIStatusMessage(Some(format!(
                    "Discarded {}",
                    result.transaction_id
                ))));
                let assistant_message_id =
                    self.agent_execution.borrow().assistant_message_id.clone();
                if let Some(aid) = assistant_message_id {
                    self.store.dispatch(EditorAction::UpdateChatMessage {
                        id: aid,
                        assistant_state: AIChatAssistantState::Discarded,
                    });
                    self.agent_execution.borrow_mut().assistant_message_id = None;
                }
                let proposal = self.agent_execution.borrow_mut().proposal.take();
                if let Some(proposal) = proposal
                    && let Some(session) = self.session.borrow().clone()
                {
                    session.record_outcome(&proposal.tool_use_id, "User rejected this plan.", Some(&proposal.id));
                }
            }
        }
    }

    /// `makeExecutionContext()` — builds the transaction-execution context that
    /// records observations under the document identity for the editor actor.
    pub(crate) fn make_execution_context(&self) -> TransactionExecutionContext {
        let scene_runtime = self.scene.scene();
        let identity = self.store.state().document.identity.to_string();
        TransactionExecutionContext::new(
            Some(scene_runtime),
            None,
            None,
            Some(self.observation_bus.clone()),
            EventOrigin::new(EventOriginProcessKind::Editor, "local-editor", Some("local-user".to_string()), None),
            identity.clone(),
            identity.clone(),
            identity.clone(),
            identity,
        )
    }

    /// `updateSelection(after:)` — selects the first created entity, or clears
    /// a selection the transaction deleted.
    fn update_selection_after_apply(&self, apply_result: Option<&TransactionApplyResult>) {
        let Some(apply_result) = apply_result else {
            return;
        };
        if let Some(created) = apply_result.created_entity_ids.first() {
            self.store
                .dispatch(EditorAction::SetSelectedEntity(Some(*created)));
            return;
        }
        if let Some(selected) = self.store.selected_entity_id()
            && apply_result.deleted_entity_ids.contains(&selected)
        {
            self.store.dispatch(EditorAction::SetSelectedEntity(None));
        }
    }

    /// `defaultSpawnMeshIndex()` — the selected entity's render mesh index, or 0.
    fn default_spawn_mesh_index(&self) -> i64 {
        let Some(entity) = self
            .entity_id(self.store.selected_entity_id())
        else {
            return 0;
        };
        use diffuse_scene::rendering::render_extraction::RenderMeshComponent;
        let scene = self.scene.scene();
        scene
            .component::<RenderMeshComponent>(entity)
            .map(|mesh| mesh.mesh_index)
            .unwrap_or(0)
    }
}
