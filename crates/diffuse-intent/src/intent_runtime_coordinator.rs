//! Commit policies, staged confirmations and shared undo/redo history.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard};

use diffuse_capability::support::disposal::Registration;
use diffuse_capability::support::swift_date::SWIFT_DATE_REFERENCE_UNIX_SECONDS;
use diffuse_observation::event_envelope::{
    EventPayloadRecord, EventPayloadRef, EventProvenance, EventValue,
};
use diffuse_observation::event_kind_registry::EventKindId;

use crate::invocation::capability_invocation::{
    ConfirmationAnswer, ConfirmationAnswerOutcome, ConfirmationOption, ConfirmationQuestion,
    ConfirmationQuestionKind, ConfirmationRequestBatch, ConfirmationResolution,
    ConfirmationSeverity,
};
use crate::invocation::capability_invocation_planning::{
    CapabilityInvocationContext, CapabilityInvocationPlanner,
};
use crate::pipeline::commit_pipeline::{
    CommitEntry, CommitHandlerError, CommitPipeline, CommitRequest, Handler,
};
use crate::planning::edit::new_uuid;
use crate::transactions::staged_transaction_store::{
    StageTransactionResult, StagedTransactionStore,
};
use crate::transactions::transaction_executor::{
    TransactionApplyResult, TransactionExecutionContext, TransactionExecutor, domain_name, integer,
};
use crate::transactions::transaction_ir::{
    TransactionApprovalPolicy, TransactionIR, TransactionPreviewResult,
};
use crate::transactions::undo_stack::UndoStack;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CapabilityInvocationDisposition {
    Applied,
    ConfirmationRequested,
    Discarded,
}

impl CapabilityInvocationDisposition {
    pub const fn raw_value(self) -> &'static str {
        match self {
            Self::Applied => "applied",
            Self::ConfirmationRequested => "confirmation_requested",
            Self::Discarded => "discarded",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CapabilityInvocationResult {
    pub disposition: CapabilityInvocationDisposition,
    pub transaction_id: String,
    pub apply_result: Option<TransactionApplyResult>,
    pub staged_result: Option<StageTransactionResult>,
    pub confirmation_request: Option<ConfirmationRequestBatch>,
    pub read_after_write: Vec<EventKindId>,
    pub warnings: Vec<String>,
}

impl CapabilityInvocationResult {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        disposition: CapabilityInvocationDisposition,
        transaction_id: impl Into<String>,
        apply_result: Option<TransactionApplyResult>,
        staged_result: Option<StageTransactionResult>,
        confirmation_request: Option<ConfirmationRequestBatch>,
        read_after_write: Vec<EventKindId>,
        warnings: Vec<String>,
    ) -> Self {
        Self {
            disposition,
            transaction_id: transaction_id.into(),
            apply_result,
            staged_result,
            confirmation_request,
            read_after_write,
            warnings,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum IntentRuntimeCoordinatorError {
    #[error("no confirmation batch is currently staged")]
    NoPendingConfirmation,
    #[error("confirmation batch mismatch: expected {expected}, actual {actual}")]
    ConfirmationBatchMismatch { expected: String, actual: String },
    #[error("confirmation answers incomplete: expected {expected}, actual {actual}")]
    IncompleteConfirmationAnswers { expected: usize, actual: usize },
    #[error("confirmation answer references unexpected question {0}")]
    UnexpectedConfirmationQuestion(String),
    #[error("confirmation option {option_id} does not belong to question {question_id}")]
    InvalidConfirmationOption {
        question_id: String,
        option_id: String,
    },
    #[error("capability-backed transactions require an invocation context")]
    MissingCapabilityContext,
}

#[derive(Clone)]
struct PendingInvocation {
    transaction: TransactionIR,
    request: ConfirmationRequestBatch,
    remaining_questions: Vec<ConfirmationQuestion>,
    preview: TransactionPreviewResult,
    capability_context: Option<CapabilityInvocationContext>,
}

struct CoordinatorState {
    capability_planner: CapabilityInvocationPlanner,
    pending: Option<PendingInvocation>,
    commit_policies: Vec<(String, Handler)>,
}

/// Swift shares this coordinator and its undo stack between UI and tool threads.
#[derive(Clone)]
pub struct IntentRuntimeCoordinator {
    executor: TransactionExecutor,
    staged_store: Arc<StagedTransactionStore>,
    state: Arc<Mutex<CoordinatorState>>,
    pub undo_stack: Arc<Mutex<UndoStack>>,
}

impl IntentRuntimeCoordinator {
    pub fn new(
        executor: TransactionExecutor,
        capability_planner: CapabilityInvocationPlanner,
        undo_stack: UndoStack,
    ) -> Self {
        Self::with_shared_undo_stack(
            executor,
            capability_planner,
            Arc::new(Mutex::new(undo_stack)),
        )
    }

    pub fn with_shared_undo_stack(
        executor: TransactionExecutor,
        capability_planner: CapabilityInvocationPlanner,
        undo_stack: Arc<Mutex<UndoStack>>,
    ) -> Self {
        Self {
            executor,
            staged_store: Arc::new(StagedTransactionStore::new(executor)),
            state: Arc::new(Mutex::new(CoordinatorState {
                capability_planner,
                pending: None,
                commit_policies: Vec::new(),
            })),
            undo_stack,
        }
    }

    fn state(&self) -> MutexGuard<'_, CoordinatorState> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    fn undo_history(&self) -> MutexGuard<'_, UndoStack> {
        self.undo_stack
            .lock()
            .unwrap_or_else(|error| error.into_inner())
    }

    pub fn pending_confirmation_request(&self) -> Option<ConfirmationRequestBatch> {
        self.state()
            .pending
            .as_ref()
            .map(|pending| pending.request.clone())
    }

    pub fn configure_capability_planner(&self, planner: CapabilityInvocationPlanner) {
        self.state().capability_planner = planner;
    }

    pub fn register_commit_policy(&self, handler: Handler) -> Registration {
        let id = new_uuid();
        self.state().commit_policies.push((id.clone(), handler));
        let state = Arc::downgrade(&self.state);
        Registration::new(move || {
            if let Some(state) = state.upgrade() {
                state
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .commit_policies
                    .retain(|(policy_id, _)| policy_id != &id);
            }
        })
    }

    fn current_pipeline(&self) -> CommitPipeline {
        let (planner, mut policies) = {
            let state = self.state();
            (
                state.capability_planner.clone(),
                state
                    .commit_policies
                    .iter()
                    .map(|(_, handler)| handler.clone())
                    .collect::<Vec<_>>(),
            )
        };
        policies.extend(CommitPipeline::standard(planner).handlers);
        CommitPipeline::new(policies)
    }

    pub fn submit_plan(
        &self,
        transaction: &TransactionIR,
        execution_context: &mut TransactionExecutionContext,
        capability_context: Option<CapabilityInvocationContext>,
        entry: CommitEntry,
    ) -> Result<CapabilityInvocationResult, CommitHandlerError> {
        let planned = self.current_pipeline().run(CommitRequest::new(
            transaction.clone(),
            capability_context,
            entry,
            Vec::new(),
            Vec::new(),
        ))?;
        self.submit_planned_transaction(
            planned.transaction,
            planned.questions,
            planned.warnings,
            planned.capability_context,
            execution_context,
        )
    }

    fn submit_planned_transaction(
        &self,
        transaction: TransactionIR,
        planned_questions: Vec<ConfirmationQuestion>,
        warnings: Vec<String>,
        capability_context: Option<CapabilityInvocationContext>,
        context: &mut TransactionExecutionContext,
    ) -> Result<CapabilityInvocationResult, CommitHandlerError> {
        if transaction.approval_policy == TransactionApprovalPolicy::Automatic {
            let undo_snapshot = context.scene_runtime.clone();
            let applied = self.executor.apply(&transaction, context)?;
            if let Some(snapshot) = undo_snapshot {
                self.undo_history().push(snapshot);
            }
            return Ok(CapabilityInvocationResult::new(
                CapabilityInvocationDisposition::Applied,
                transaction.id,
                Some(applied),
                None,
                None,
                Vec::new(),
                warnings,
            ));
        }
        let staged_result = self.staged_store.stage(&transaction, context)?;
        let destructive_questions = if transaction.capability_invocations.is_empty() {
            Vec::new()
        } else {
            planned_questions
                .iter()
                .filter(|q| q.kind == ConfirmationQuestionKind::ApproveDestructive)
                .cloned()
                .collect::<Vec<_>>()
        };
        let initial_questions = if destructive_questions.is_empty() {
            planned_questions
        } else {
            planned_questions
                .into_iter()
                .filter(|q| q.kind != ConfirmationQuestionKind::ApproveDestructive)
                .collect()
        };
        let request = self.make_confirmation_request(&transaction, initial_questions);
        let publication = self.publish_confirmation_requested(
            &request,
            &staged_result.preview,
            &transaction.id,
            context,
        );
        if let Err(error) = publication {
            let _ = self.staged_store.discard_staged_transaction(Some(context));
            return Err(error.into());
        }
        self.state().pending = Some(PendingInvocation {
            transaction: transaction.clone(),
            request: request.clone(),
            remaining_questions: destructive_questions,
            preview: staged_result.preview.clone(),
            capability_context,
        });
        Ok(CapabilityInvocationResult::new(
            CapabilityInvocationDisposition::ConfirmationRequested,
            transaction.id,
            None,
            Some(staged_result),
            Some(request),
            Vec::new(),
            warnings,
        ))
    }

    pub fn undo(&self, context: &mut TransactionExecutionContext) -> bool {
        let Some(current) = context.scene_runtime.as_ref() else {
            return false;
        };
        let Some(snapshot) = self.undo_history().undo(current.clone()) else {
            return false;
        };
        context.scene_runtime = Some(snapshot);
        true
    }

    pub fn redo(&self, context: &mut TransactionExecutionContext) -> bool {
        let Some(current) = context.scene_runtime.as_ref() else {
            return false;
        };
        let Some(snapshot) = self.undo_history().redo(current.clone()) else {
            return false;
        };
        context.scene_runtime = Some(snapshot);
        true
    }

    pub fn resolve_plan_confirmation(
        &self,
        resolution: &ConfirmationResolution,
        context: &mut TransactionExecutionContext,
    ) -> Result<CapabilityInvocationResult, CommitHandlerError> {
        let pending = self.locked_pending(&resolution.batch_id)?;
        validate_confirmation_resolution(resolution, &pending.request)?;
        if let Some(bus) = &context.observation_bus {
            let _ = bus.publish(
                EventKindId::ConfirmationResolved,
                &context.ui_stream_id,
                EventPayloadRef::Inline {
                    record: self.confirmation_resolved_payload(resolution, &pending.transaction.id),
                },
                context.event_origin.clone(),
                None,
                Some(pending.transaction.id.clone()),
                Some(resolution.correlation_id.clone()),
                EventProvenance::Authored,
                1,
            )?;
        }
        if self.should_apply(resolution) {
            if !pending.remaining_questions.is_empty() {
                let next_request = ConfirmationRequestBatch::new(
                    format!("cfm:destructive:{}", pending.transaction.id),
                    "intent_runtime",
                    &pending.transaction.id,
                    pending.remaining_questions.clone(),
                );
                self.publish_confirmation_requested(
                    &next_request,
                    &pending.preview,
                    &pending.transaction.id,
                    context,
                )?;
                self.state().pending = Some(PendingInvocation {
                    transaction: pending.transaction.clone(),
                    request: next_request.clone(),
                    remaining_questions: Vec::new(),
                    preview: pending.preview,
                    capability_context: pending.capability_context,
                });
                return Ok(CapabilityInvocationResult::new(
                    CapabilityInvocationDisposition::ConfirmationRequested,
                    pending.transaction.id,
                    None,
                    None,
                    Some(next_request),
                    Vec::new(),
                    Vec::new(),
                ));
            }
            if !pending.transaction.capability_invocations.is_empty()
                && let Some(original_context) = &pending.capability_context
            {
                let mut current_context = original_context.clone();
                if let Some(scene) = &context.scene_runtime {
                    current_context = CapabilityInvocationContext::from_scene_runtime(
                        scene,
                        original_context.selected_entity_id,
                        original_context.is_scene_editable,
                        original_context.default_source,
                        original_context.default_confidence,
                        original_context.default_evidence.clone(),
                    );
                }
                let planner = self.state().capability_planner.clone();
                let revalidation = CommitPipeline::standard(planner).run(CommitRequest::new(
                    pending.transaction.clone(),
                    Some(current_context),
                    CommitEntry::Ui,
                    Vec::new(),
                    Vec::new(),
                ));
                if let Err(error) = revalidation {
                    let _ = self.staged_store.discard_staged_transaction(Some(context));
                    self.state().pending = None;
                    return Err(error);
                }
            }
            let undo_snapshot = context.scene_runtime.clone();
            let applied = self.staged_store.apply_staged_transaction(context)?;
            if let Some(snapshot) = undo_snapshot {
                self.undo_history().push(snapshot);
            }
            self.state().pending = None;
            return Ok(CapabilityInvocationResult::new(
                CapabilityInvocationDisposition::Applied,
                pending.transaction.id,
                applied.apply_result,
                None,
                None,
                Vec::new(),
                Vec::new(),
            ));
        }
        let _ = self
            .staged_store
            .discard_staged_transaction(Some(context))?;
        self.state().pending = None;
        Ok(CapabilityInvocationResult::new(
            CapabilityInvocationDisposition::Discarded,
            pending.transaction.id,
            None,
            None,
            None,
            Vec::new(),
            Vec::new(),
        ))
    }

    fn locked_pending(
        &self,
        batch_id: &str,
    ) -> Result<PendingInvocation, IntentRuntimeCoordinatorError> {
        let pending = self
            .state()
            .pending
            .clone()
            .ok_or(IntentRuntimeCoordinatorError::NoPendingConfirmation)?;
        if pending.request.batch_id != batch_id {
            return Err(IntentRuntimeCoordinatorError::ConfirmationBatchMismatch {
                expected: pending.request.batch_id,
                actual: batch_id.to_string(),
            });
        }
        Ok(pending)
    }

    fn make_confirmation_request(
        &self,
        transaction: &TransactionIR,
        planned_questions: Vec<ConfirmationQuestion>,
    ) -> ConfirmationRequestBatch {
        let mut question = ConfirmationQuestion::new(
            format!("plan:{}", transaction.id),
            ConfirmationQuestionKind::ApproveDestructive,
            &transaction.summary,
            ConfirmationSeverity::Warn,
            true,
            0.5,
        );
        let mut confirm = ConfirmationOption::new("confirm", "Apply");
        confirm.label_detail = Some("Execute the scene edit plan".to_string());
        let mut skip = ConfirmationOption::new("skip", "Discard");
        skip.label_detail = Some("Discard without applying".to_string());
        question.options = vec![confirm, skip];
        question.default_option_id = Some("confirm".to_string());
        question.source_proposal_ids = vec![transaction.id.clone()];
        ConfirmationRequestBatch::new(
            format!("cfm:{}", transaction.id),
            "intent_runtime",
            &transaction.id,
            if planned_questions.is_empty() {
                vec![question]
            } else {
                planned_questions
            },
        )
    }

    fn should_apply(&self, resolution: &ConfirmationResolution) -> bool {
        if resolution.partial || resolution.answers.is_empty() {
            return false;
        }
        resolution
            .answers
            .iter()
            .all(|answer| match answer.outcome {
                ConfirmationAnswerOutcome::Accepted
                | ConfirmationAnswerOutcome::Renamed
                | ConfirmationAnswerOutcome::Scoped
                | ConfirmationAnswerOutcome::Adjusted => true,
                ConfirmationAnswerOutcome::Rejected | ConfirmationAnswerOutcome::Skipped => false,
            })
    }

    fn publish_confirmation_requested(
        &self,
        request: &ConfirmationRequestBatch,
        preview: &TransactionPreviewResult,
        transaction_id: &str,
        context: &TransactionExecutionContext,
    ) -> Result<(), diffuse_observation::cold_log::ObservationBusError> {
        if let Some(bus) = &context.observation_bus {
            let _ = bus.publish(
                EventKindId::ConfirmationRequested,
                &context.ui_stream_id,
                EventPayloadRef::Inline {
                    record: self.confirmation_requested_payload(request, preview),
                },
                context.event_origin.clone(),
                None,
                Some(transaction_id.to_string()),
                Some(request.correlation_id.clone()),
                EventProvenance::Authored,
                1,
            )?;
        }
        Ok(())
    }

    fn confirmation_requested_payload(
        &self,
        request: &ConfirmationRequestBatch,
        preview: &TransactionPreviewResult,
    ) -> EventPayloadRecord {
        let strings = |values: &[String]| {
            EventValue::Array(values.iter().cloned().map(EventValue::String).collect())
        };
        let entity_ids = |values: &[u64]| {
            EventValue::Array(values.iter().map(|&value| integer(value)).collect())
        };
        let mut payload = BTreeMap::from([
            (
                "batch_id".to_string(),
                EventValue::String(request.batch_id.clone()),
            ),
            (
                "origin".to_string(),
                EventValue::String(request.origin.clone()),
            ),
            (
                "correlation_id".to_string(),
                EventValue::String(request.correlation_id.clone()),
            ),
            (
                "questions".to_string(),
                EventValue::Array(
                    request
                        .questions
                        .iter()
                        .map(|q| self.question_payload(q))
                        .collect(),
                ),
            ),
            (
                "preview".to_string(),
                EventValue::Object(BTreeMap::from([
                    (
                        "changed_domains".to_string(),
                        EventValue::Array(
                            preview
                                .changed_domains
                                .iter()
                                .map(|d| EventValue::String(domain_name(*d).to_string()))
                                .collect(),
                        ),
                    ),
                    (
                        "created_entity_ids".to_string(),
                        entity_ids(&preview.created_entity_ids),
                    ),
                    (
                        "deleted_entity_ids".to_string(),
                        entity_ids(&preview.deleted_entity_ids),
                    ),
                    (
                        "mutations".to_string(),
                        strings(&preview.mutation_summaries),
                    ),
                ])),
            ),
        ]);
        if let Some(uri) = &request.context_snapshot_uri {
            payload.insert(
                "context_snapshot_uri".to_string(),
                EventValue::String(uri.clone()),
            );
        }
        payload
    }

    fn confirmation_resolved_payload(
        &self,
        resolution: &ConfirmationResolution,
        transaction_id: &str,
    ) -> EventPayloadRecord {
        let milliseconds =
            (resolution.decided_at.0 + SWIFT_DATE_REFERENCE_UNIX_SECONDS as f64) * 1000.0;
        assert!(
            milliseconds.is_finite()
                && milliseconds >= i64::MIN as f64
                && milliseconds < 9_223_372_036_854_775_808.0,
            "confirmation time must fit Swift Int64"
        );
        let mut payload = BTreeMap::from([
            (
                "batch_id".to_string(),
                EventValue::String(resolution.batch_id.clone()),
            ),
            (
                "correlation_id".to_string(),
                EventValue::String(resolution.correlation_id.clone()),
            ),
            (
                "transaction_id".to_string(),
                EventValue::String(transaction_id.to_string()),
            ),
            (
                "answers".to_string(),
                EventValue::Array(
                    resolution
                        .answers
                        .iter()
                        .map(|a| self.answer_payload(a))
                        .collect(),
                ),
            ),
            (
                "partial".to_string(),
                EventValue::Boolean(resolution.partial),
            ),
            (
                "decided_at_ms".to_string(),
                EventValue::Integer(milliseconds as i64),
            ),
        ]);
        if let Some(user_id) = &resolution.user_id {
            payload.insert("user_id".to_string(), EventValue::String(user_id.clone()));
        }
        payload
    }

    fn question_payload(&self, question: &ConfirmationQuestion) -> EventValue {
        let severity = match question.severity {
            ConfirmationSeverity::Info => "info",
            ConfirmationSeverity::Warn => "warn",
            ConfirmationSeverity::Destructive => "destructive",
        };
        EventValue::Object(BTreeMap::from([
            ("id".to_string(), EventValue::String(question.id.clone())),
            (
                "kind".to_string(),
                EventValue::String(question.kind.raw_value().to_string()),
            ),
            (
                "prompt_short".to_string(),
                EventValue::String(question.prompt_short.clone()),
            ),
            (
                "prompt_detail".to_string(),
                optional_string(&question.prompt_detail),
            ),
            (
                "options".to_string(),
                EventValue::Array(
                    question
                        .options
                        .iter()
                        .map(|o| self.option_payload(o))
                        .collect(),
                ),
            ),
            (
                "default_option".to_string(),
                optional_string(&question.default_option_id),
            ),
            (
                "severity".to_string(),
                EventValue::String(severity.to_string()),
            ),
            (
                "reversible".to_string(),
                EventValue::Boolean(question.reversible),
            ),
            (
                "ambiguity_score".to_string(),
                EventValue::Number(question.ambiguity_score),
            ),
            (
                "source_proposal_ids".to_string(),
                EventValue::Array(
                    question
                        .source_proposal_ids
                        .iter()
                        .cloned()
                        .map(EventValue::String)
                        .collect(),
                ),
            ),
        ]))
    }

    fn option_payload(&self, option: &ConfirmationOption) -> EventValue {
        EventValue::Object(BTreeMap::from([
            ("id".to_string(), EventValue::String(option.id.clone())),
            (
                "label_short".to_string(),
                EventValue::String(option.label_short.clone()),
            ),
            (
                "label_detail".to_string(),
                optional_string(&option.label_detail),
            ),
            (
                "side_effect_summary".to_string(),
                optional_string(&option.side_effect_summary),
            ),
        ]))
    }

    fn answer_payload(&self, answer: &ConfirmationAnswer) -> EventValue {
        let outcome = match answer.outcome {
            ConfirmationAnswerOutcome::Accepted => "accepted",
            ConfirmationAnswerOutcome::Rejected => "rejected",
            ConfirmationAnswerOutcome::Skipped => "skipped",
            ConfirmationAnswerOutcome::Renamed => "renamed",
            ConfirmationAnswerOutcome::Scoped => "scoped",
            ConfirmationAnswerOutcome::Adjusted => "adjusted",
        };
        EventValue::Object(BTreeMap::from([
            (
                "question_id".to_string(),
                EventValue::String(answer.question_id.clone()),
            ),
            (
                "outcome".to_string(),
                EventValue::String(outcome.to_string()),
            ),
            (
                "picked_option_id".to_string(),
                optional_string(&answer.picked_option_id),
            ),
            ("note".to_string(), optional_string(&answer.note)),
        ]))
    }
}

impl Default for IntentRuntimeCoordinator {
    fn default() -> Self {
        Self::new(
            TransactionExecutor::new(),
            CapabilityInvocationPlanner::default(),
            UndoStack::default(),
        )
    }
}

fn optional_string(value: &Option<String>) -> EventValue {
    value
        .as_ref()
        .map(|value| EventValue::String(value.clone()))
        .unwrap_or(EventValue::Null)
}

pub fn validate_confirmation_resolution(
    resolution: &ConfirmationResolution,
    request: &ConfirmationRequestBatch,
) -> Result<(), IntentRuntimeCoordinatorError> {
    let expected_ids: BTreeSet<_> = request.questions.iter().map(|q| q.id.as_str()).collect();
    let actual_ids: BTreeSet<_> = resolution
        .answers
        .iter()
        .map(|a| a.question_id.as_str())
        .collect();
    if resolution.answers.len() != request.questions.len() || actual_ids != expected_ids {
        if let Some(unexpected) = actual_ids.difference(&expected_ids).next() {
            return Err(
                IntentRuntimeCoordinatorError::UnexpectedConfirmationQuestion(
                    (*unexpected).to_string(),
                ),
            );
        }
        return Err(
            IntentRuntimeCoordinatorError::IncompleteConfirmationAnswers {
                expected: request.questions.len(),
                actual: resolution.answers.len(),
            },
        );
    }
    let mut questions_by_id = BTreeMap::new();
    for question in &request.questions {
        assert!(
            questions_by_id
                .insert(question.id.as_str(), question)
                .is_none(),
            "Duplicate values for question ID"
        );
    }
    for answer in &resolution.answers {
        let question = questions_by_id
            .get(answer.question_id.as_str())
            .ok_or_else(|| {
                IntentRuntimeCoordinatorError::UnexpectedConfirmationQuestion(
                    answer.question_id.clone(),
                )
            })?;
        if let Some(option_id) = &answer.picked_option_id
            && !question.options.iter().any(|o| &o.id == option_id)
        {
            return Err(IntentRuntimeCoordinatorError::InvalidConfirmationOption {
                question_id: answer.question_id.clone(),
                option_id: option_id.clone(),
            });
        }
    }
    Ok(())
}
