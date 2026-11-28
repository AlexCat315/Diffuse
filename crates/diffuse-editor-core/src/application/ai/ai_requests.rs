//! `Editor/Sources/EditorCore/Application/AI/AIRequests.swift`.
//!
//! Commit-policy installation, plan submission and confirmation resolution.
//! `submitNaturalLanguageIntent` lands with the session wiring in `Plugins.swift`
//! (`activatePlugins`, harness activation), which this extension calls.

use std::collections::BTreeSet;

use diffuse_intent::intent_runtime_coordinator::CapabilityInvocationResult;
use diffuse_intent::invocation::capability_invocation::{
    ConfirmationAnswer, ConfirmationAnswerOutcome, ConfirmationResolution,
};
use diffuse_intent::invocation::capability_invocation_planning::CapabilityInvocationContext;
use diffuse_intent::transactions::transaction_ir::TransactionOperation;
use diffuse_intent::pipeline::commit_pipeline::{
    CommitDecision, CommitEntry, CommitHandlerError, CommitRequest,
};
use diffuse_intent::transactions::transaction_ir::TransactionIR;
use diffuse_scene::entity_id::EntityID;

use crate::ai::chat::editor_ai_request_policy::EditorPlanSubmissionError;
use crate::application::editor_application::{EditorApplication, SendableAppHandle};
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::EditorConsoleSeverity;
use crate::state::workspace::editor_workbench_state::EditorIssueTarget;

impl EditorApplication {
    /// Entry policies for every plan submission (UI, MCP, headless). Called
    /// once at construction; the pipeline runs them before the standard
    /// capability gates so denial precedence matches the previous pre-flight
    /// checks, and the gates still always run.
    pub fn install_commit_policies(self: &std::rc::Rc<Self>) {
        {
            let app = SendableAppHandle(std::rc::Rc::downgrade(self));
            self.intent_coordinator
                .register_commit_policy(std::sync::Arc::new(move |request: CommitRequest| {
                    let Some(app) = app.upgrade() else {
                        return Ok(CommitDecision::Proceed(request));
                    };
                    if app.store.pending_confirmation_request().is_some() {
                        return Err(Box::new(EditorPlanSubmissionError::PendingConfirmation));
                    }
                    Ok(CommitDecision::Proceed(request))
                }));
        }
        {
            let app = SendableAppHandle(std::rc::Rc::downgrade(self));
            self.intent_coordinator
                .register_commit_policy(std::sync::Arc::new(move |request: CommitRequest| {
                    let Some(app) = app.upgrade() else {
                        return Ok(CommitDecision::Proceed(request));
                    };
                    let locked: Vec<u64> = app
                        .referenced_existing_entity_ids(&request.transaction)
                        .into_iter()
                        .filter(|id| app.scene.is_entity_locked(*id))
                        .collect();
                    if !locked.is_empty() {
                        return Err(Box::new(EditorPlanSubmissionError::LockedEntities(locked)));
                    }
                    Ok(CommitDecision::Proceed(request))
                }));
        }
    }

    /// `submitPlanTransaction(_:capabilityContext:entry:)`.
    pub fn submit_plan_transaction(
        &self,
        transaction: &TransactionIR,
        capability_context: Option<CapabilityInvocationContext>,
        entry: CommitEntry,
    ) -> Result<CapabilityInvocationResult, CommitHandlerError> {
        self.run_plan_transaction(transaction, capability_context, entry)
    }

    /// `runPlanTransaction(_:capabilityContext:entry:)` — submits, applies the
    /// result, and records the confirmation target set when review is required.
    pub fn run_plan_transaction(
        &self,
        transaction: &TransactionIR,
        capability_context: Option<CapabilityInvocationContext>,
        entry: CommitEntry,
    ) -> Result<CapabilityInvocationResult, CommitHandlerError> {
        // Pending-confirmation and entity-lock checks live in the registered
        // commit policies; the target set is still computed here for
        // confirmation bookkeeping.
        let target_entity_ids = self.referenced_existing_entity_ids(transaction);
        let mut context = self.make_execution_context();
        let result = self.intent_coordinator.submit_plan(
            transaction,
            &mut context,
            capability_context,
            entry,
        )?;
        if result.disposition == diffuse_intent::intent_runtime_coordinator::CapabilityInvocationDisposition::ConfirmationRequested
        {
            self.agent_execution.borrow_mut().confirmation_target_entity_ids = target_entity_ids;
        }
        self.apply_invocation_result(&result, &mut context);
        Ok(result)
    }

    /// `referencedExistingEntityIDs(in:)` — every existing entity whose state or
    /// hierarchy the transaction directly references. Parent IDs matter as well:
    /// spawning or moving a child changes the locked parent's hierarchy even
    /// when the child itself is new.
    pub(crate) fn referenced_existing_entity_ids(&self, transaction: &TransactionIR) -> BTreeSet<u64> {
        let mut result: BTreeSet<u64> = BTreeSet::new();
        let scene = self.scene.scene();

        let insert_parent = |result: &mut BTreeSet<u64>, raw_id: u64| {
            let Some(entity) = self.entity_id(Some(raw_id)) else {
                return;
            };
            if !scene.contains(entity) {
                return;
            }
            if let Some(parent) = scene.parent(entity) {
                result.insert(parent.raw_value());
            }
        };

        for operation in &transaction.operations {
            let TransactionOperation::Scene(mutation) = operation else {
                continue;
            };
            if let Some(entity_id) = mutation.entity_id() {
                result.insert(entity_id);
            }
            match mutation {
                diffuse_intent::transactions::transaction_ir::SceneMutation::SpawnImportedMeshEntity {
                    parent_id,
                    ..
                }
                | diffuse_intent::transactions::transaction_ir::SceneMutation::SpawnEmptyEntity {
                    parent_id,
                    ..
                }
                | diffuse_intent::transactions::transaction_ir::SceneMutation::SpawnLightEntity {
                    parent_id,
                    ..
                }
                | diffuse_intent::transactions::transaction_ir::SceneMutation::SpawnCameraEntity {
                    parent_id,
                    ..
                } => {
                    if let Some(parent_id) = parent_id {
                        result.insert(*parent_id);
                    }
                }
                diffuse_intent::transactions::transaction_ir::SceneMutation::MoveEntity {
                    entity_id,
                    parent_id,
                    ..
                } => {
                    insert_parent(&mut result, *entity_id);
                    if let Some(parent_id) = parent_id {
                        result.insert(*parent_id);
                    }
                }
                diffuse_intent::transactions::transaction_ir::SceneMutation::DeleteEntity {
                    entity_id,
                } => {
                    insert_parent(&mut result, *entity_id);
                    if let Some(entity) = self.entity_id(Some(*entity_id))
                        && scene.contains(entity)
                    {
                        result.extend(scene.children(entity).into_iter().map(|child| child.raw_value()));
                    }
                }
                _ => {}
            }
        }
        result
    }

    /// `resolvePendingConfirmation(pickedOptionIDsByQuestionID:)`.
    pub fn resolve_pending_confirmation_selections(
        &self,
        selections: &std::collections::BTreeMap<String, String>,
    ) {
        let Some(request) = self.store.pending_confirmation_request() else {
            self.store.dispatch(EditorAction::SetAIStatusMessage(Some(
                "No confirmation request is pending.".into(),
            )));
            return;
        };
        if request.questions.is_empty() {
            self.store.dispatch(EditorAction::SetAIStatusMessage(Some(
                "No confirmation request is pending.".into(),
            )));
            return;
        }
        let mut answers: Vec<ConfirmationAnswer> = Vec::new();
        for question in &request.questions {
            let Some(picked_option_id) = selections.get(&question.id) else {
                self.store.dispatch(EditorAction::SetAIStatusMessage(Some(
                    "Choose an option for every confirmation item before continuing.".into(),
                )));
                return;
            };
            if !question
                .options
                .iter()
                .any(|option| &option.id == picked_option_id)
            {
                self.store.dispatch(EditorAction::SetAIStatusMessage(Some(
                    "Choose an option for every confirmation item before continuing.".into(),
                )));
                return;
            }
            let normalized = picked_option_id.to_lowercase();
            let outcome = if ["skip", "discard", "reject", "deny", "cancel"]
                .contains(&normalized.as_str())
            {
                ConfirmationAnswerOutcome::Skipped
            } else {
                ConfirmationAnswerOutcome::Accepted
            };
            let mut answer =
                ConfirmationAnswer::new(question.id.clone(), outcome);
            answer.picked_option_id = Some(picked_option_id.clone());
            answers.push(answer);
        }
        self.resolve_pending_confirmation(&ConfirmationResolution::new(
            request.batch_id.clone(),
            request.correlation_id.clone(),
            answers,
            false,
        ));
    }

    /// `resolvePendingConfirmation(_:)` — refuses a locked target while a
    /// mutation is accepted, then applies the coordinator's result.
    pub(crate) fn resolve_pending_confirmation(&self, resolution: &ConfirmationResolution) {
        let locked_entity_ids: Vec<u64> = self
            .agent_execution
            .borrow()
            .confirmation_target_entity_ids
            .iter()
            .copied()
            .filter(|id| self.scene.is_entity_locked(*id))
            .collect();
        let accepts_any_mutation = resolution
            .answers
            .iter()
            .any(|answer| answer.outcome == ConfirmationAnswerOutcome::Accepted);
        if !locked_entity_ids.is_empty() && accepts_any_mutation {
            let labels = locked_entity_ids
                .iter()
                .map(u64::to_string)
                .collect::<Vec<_>>()
                .join(", ");
            self.store.dispatch(EditorAction::SetAIStatusMessage(Some(format!(
                "The pending plan targets locked entities: {labels}. \
                 Discard this confirmation, unlock them, and submit the action again."
            ))));
            return;
        }
        let mut context = self.make_execution_context();
        let target = self
            .agent_task_service
            .borrow()
            .active_task()
            .map(|task| task.target.clone());
        let result = (|| {
            if accepts_any_mutation
                && let Some(target) = &target
            {
                self.validate_agent_task_target(target)?;
            }
            self.intent_coordinator
                .resolve_plan_confirmation(resolution, &mut context)
                .map_err(|error| {
                    crate::ai::editor_project_tools::EditorProjectToolError::new(error.to_string())
                })
        })();
        match result {
            Ok(result) => self.apply_invocation_result(&result, &mut context),
            // Keep review active so the user can discard a stale proposal.
            Err(error) => self
                .store
                .dispatch(EditorAction::SetAIStatusMessage(Some(error.to_string()))),
        }
    }

    /// `resolvePendingConfirmation(pickedOptionID:)`.
    pub fn resolve_pending_confirmation_picked_option(&self, picked_option_id: &str) {
        let Some(request) = self.store.pending_confirmation_request() else {
            self.store.dispatch(EditorAction::SetAIStatusMessage(Some(
                "No confirmation request is pending.".into(),
            )));
            return;
        };
        let selections: std::collections::BTreeMap<String, String> = request
            .questions
            .iter()
            .filter(|question| {
                question
                    .options
                    .iter()
                    .any(|option| option.id == picked_option_id)
            })
            .map(|question| (question.id.clone(), picked_option_id.to_string()))
            .collect();
        self.resolve_pending_confirmation_selections(&selections);
    }

    /// `acceptPendingConfirmation()` — picks each question's default option, or
    /// its first option when no default is set.
    pub fn accept_pending_confirmation(&self) {
        let Some(request) = self.store.pending_confirmation_request() else {
            self.store.dispatch(EditorAction::SetAIStatusMessage(Some(
                "No confirmation request is pending.".into(),
            )));
            return;
        };
        let selections: std::collections::BTreeMap<String, String> = request
            .questions
            .iter()
            .filter_map(|question| {
                let option_id = question
                    .default_option_id
                    .clone()
                    .or_else(|| question.options.first().map(|option| option.id.clone()))?;
                Some((question.id.clone(), option_id))
            })
            .collect();
        self.resolve_pending_confirmation_selections(&selections);
    }

    /// `skipPendingConfirmation()` — answers every question with the first
    /// skip/reject option and drops the review state.
    pub fn skip_pending_confirmation(&self) {
        let Some(request) = self.store.pending_confirmation_request() else {
            self.store.dispatch(EditorAction::SetAIStatusMessage(Some(
                "No confirmation request is pending.".into(),
            )));
            return;
        };
        let answers: Vec<ConfirmationAnswer> = request
            .questions
            .iter()
            .map(|question| {
                let option_id = question
                    .options
                    .iter()
                    .find(|option| {
                        ["skip", "discard", "reject", "deny", "cancel"]
                            .contains(&option.id.to_lowercase().as_str())
                    })
                    .map(|option| option.id.clone());
                let mut answer =
                    ConfirmationAnswer::new(question.id.clone(), ConfirmationAnswerOutcome::Skipped);
                answer.picked_option_id = option_id;
                answer
            })
            .collect();
        self.resolve_pending_confirmation(&ConfirmationResolution::new(
            request.batch_id.clone(),
            request.correlation_id.clone(),
            answers,
            false,
        ));
        // A staging record that never reached the pipeline (or failed to
        // resolve) still has to leave review; the pipeline clears it itself on
        // the discard path, so this only runs for the leftover case.
        if self.store.pending_confirmation_request().is_some() {
            self.drop_agent_execution();
        }
    }

    /// The bookkeeping `skipPendingConfirmation` performs when the pipeline
    /// never owned the request.
    fn drop_agent_execution(&self) {
        self.store
            .dispatch(EditorAction::SetPendingConfirmationRequest(None));
        self.store.dispatch(EditorAction::SetAgentCanvas(None));
        let mut exec = self.agent_execution.borrow_mut();
        exec.assistant_message_id = None;
        exec.proposal = None;
        exec.request_task.take();
    }

    /// `logConsole` convenience for the confirmation paths.
    pub(crate) fn log_plan_error(&self, message: &str, detail: String) {
        self.log_console(
            message,
            EditorConsoleSeverity::Error,
            Some(detail),
            Option::<EditorIssueTarget>::None,
            None,
        );
    }

}
