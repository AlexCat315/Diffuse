//! Ported from `Engine/Sources/AIRuntime/Session/Session.swift`.
//!
//! Swift's `actor Session` becomes a plain struct whose state sits behind one
//! `Mutex`. Locks are only held while reading or writing state, never across
//! network I/O, so `cancel_active_run` stays effective for an in-flight turn.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cove_http::{
    Client as HttpClient, ClientConfig, HttpError, Request as HttpRequest, Response as HttpResponse,
};
use diffuse_capability::capability_contract::{
    CapabilityAccess, CapabilityContract, CapabilityExposurePolicy, CapabilityExposureSnapshot,
    ReleasePhase,
};
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::capsule_schema::JsonSchemaValidator;
use diffuse_capability::contracts::exports::SessionApiFormat;
use diffuse_capability::support::swift_date::SwiftDate as CapabilitySwiftDate;
use diffuse_context_memory::context_entry::{ContextEntry, EntryKind};
use diffuse_context_memory::context_memory_store::{ContextMemoryError, ContextMemoryStore};
use diffuse_intent::transactions::transaction_ir::TransactionApprovalPolicy;
use diffuse_intent::transactions::world_event::{WorldEvent, WorldPropertyValue};
use diffuse_kernel::codable::format_float;
use diffuse_observation::publisher::ObservationBus;
use diffuse_perception::core::perception_contracts::PerceptionTask;
use diffuse_perception::core::perception_service::PerceptionService;
use diffuse_perception::{PerceptionRuntimeError, SwiftDate};
use diffuse_plugin::Uuid;
use diffuse_plugin::base64_data::Data;
use diffuse_plugin::contract::plugin_json::PluginJSON;
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::components::inspection::inspection::ComponentDescription;
use diffuse_scene::scene_runtime::SceneRuntime;
use serde_json::{Map, Value, json};

use crate::context::workflow_context::WorkflowContext;
use crate::context::world_view::{WorldEntityRecord, WorldView};
use crate::planning::capability_draft_pipeline::{
    CapabilityDraftError, CapabilityInvocationDraft, SceneCapabilityDraftLowering,
};
use crate::planning::proposal::Proposal;
use crate::planning::scene_edit_plan::{SceneEditOp, SceneEditPlan};
use crate::session::capability_state::SessionCapabilityState;
use crate::session::conversation_turn::{ConversationTurn, ConversationTurnKind};
use crate::session::harness::{
    SessionHarness, SessionHarnessState, SessionHarnessStep, SessionHarnessStepAction,
    SessionHarnessTurn, SessionHarnessTurnCall, SessionHarnessTurnObservation,
    SessionHarnessTurnRequest, SessionHarnessTurnTool,
};
use crate::session::retry_policy::RetryPolicy;
use crate::session::session_config::SessionConfig;
use crate::session::session_workflow_scope::{
    SessionContextSection, SessionContextSource, SessionWorkflowScope,
};
use crate::session::signal::Signal;
use crate::tools::capability_toolset::CapabilityToolset;
use crate::tools::plugin_capability_executor::{
    PluginCapabilityExecutionFailure, PluginCapabilityExecutor, PluginQuerySnapshotProvider,
};
use crate::tools::project_toolset::{Executor as ProjectToolExecutor, ProjectToolset};
use crate::tools::tool_policy::{ToolCall, ToolCallOrigin, ToolPolicy, ToolPolicyError};

/// `SessionError` — every failure the Swift actor surfaced.
#[derive(Debug)]
pub enum SessionError {
    UnsupportedSignal(String),
    HttpError {
        status_code: i64,
        body: Option<String>,
    },
    MalformedResponse {
        detail: String,
    },
    NoPlanInResponse,
    PlanDecodingFailed {
        detail: String,
    },
    InferenceAlreadyRunning,
    InferenceCancelled,
    /// A draft or capability failure surfaced while handling a tool call.
    Draft(CapabilityDraftError),
    /// A host tool policy refused or malformed a call.
    ToolPolicy(ToolPolicyError),
    /// Anything else the Swift `throws` carried, flattened to text.
    Other(String),
}

impl SessionError {
    pub fn malformed(detail: impl Into<String>) -> Self {
        SessionError::MalformedResponse {
            detail: detail.into(),
        }
    }

    pub fn decoding(detail: impl Into<String>) -> Self {
        SessionError::PlanDecodingFailed {
            detail: detail.into(),
        }
    }
}

impl std::fmt::Display for SessionError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SessionError::UnsupportedSignal(kind) => {
                write!(formatter, "Session: signal '{kind}' not yet handled")
            }
            SessionError::HttpError { status_code, body } => write!(
                formatter,
                "Session inference HTTP {status_code}: {}",
                body.as_deref().unwrap_or("(no body)")
            ),
            SessionError::MalformedResponse { detail } => {
                write!(formatter, "Session: malformed response — {detail}")
            }
            SessionError::NoPlanInResponse => {
                formatter.write_str("Session: model did not return a plan")
            }
            SessionError::PlanDecodingFailed { detail } => {
                write!(formatter, "Session: plan decoding failed — {detail}")
            }
            SessionError::InferenceAlreadyRunning => {
                formatter.write_str("Session: another AI run is already active")
            }
            SessionError::InferenceCancelled => {
                formatter.write_str("Session: AI run was cancelled")
            }
            SessionError::Draft(error) => error.fmt(formatter),
            SessionError::ToolPolicy(error) => error.fmt(formatter),
            SessionError::Other(message) => formatter.write_str(message),
        }
    }
}

impl std::error::Error for SessionError {}

impl From<CapabilityDraftError> for SessionError {
    fn from(error: CapabilityDraftError) -> Self {
        SessionError::Draft(error)
    }
}

impl From<ToolPolicyError> for SessionError {
    fn from(error: ToolPolicyError) -> Self {
        SessionError::ToolPolicy(error)
    }
}

impl From<PluginCapabilityExecutionFailure> for SessionError {
    fn from(error: PluginCapabilityExecutionFailure) -> Self {
        SessionError::Other(error.to_string())
    }
}

/// Progress for streaming summaries; Swift's `@Sendable (String) -> Void`.
pub type SessionProgressHandler = dyn Fn(String) + Send + Sync;

/// Swift's `ComponentDescriptionProvider`, made blocking.
pub type ComponentDescriptionProvider =
    Arc<dyn Fn(Option<&str>) -> Vec<ComponentDescription> + Send + Sync>;

/// Intermediate result of one API round-trip.
#[derive(Clone, Debug, PartialEq)]
struct RawToolCall {
    name: String,
    id: String,
    input_json: String,
    input: Map<String, Value>,
}

/// What one capability tool call produced.
enum CapabilityToolHandling {
    Exchange {
        result_json: String,
        snapshot: CapabilityExposureSnapshot,
    },
    Completed {
        plan: SceneEditPlan,
        input_json: String,
        snapshot: CapabilityExposureSnapshot,
    },
}

/// Everything the Swift actor kept in one place.
struct SessionState {
    world_view: WorldView,
    conversation_history: Vec<ConversationTurn>,
    workflow_scope: SessionWorkflowScope,
    observation_bus: Option<Arc<ObservationBus>>,
    context_memory: Option<Arc<ContextMemoryStore>>,
    cached_memory_view: Vec<BTreeMap<String, String>>,
    perception_service: Option<Arc<PerceptionService>>,
    current_locale: Option<String>,
    harness: SessionHarnessState,
    capabilities: SessionCapabilityState,
    active_inference_id: Option<String>,
    project_tool_executor: Option<ProjectToolExecutor>,
    tool_policy: Option<ToolPolicy>,
    component_description_provider: Option<ComponentDescriptionProvider>,
}

/// Per-project persistent AI participant.
///
/// Maintains `WorldView` (incremental scene understanding) and conversation
/// history, receives signals, runs inference and produces proposals. Inference
/// is built in; the session is the AI, not a dispatcher to an external backend.
pub struct Session {
    pub id: String,
    config: SessionConfig,
    client: HttpClient,
    max_history_turns: usize,
    state: Mutex<SessionState>,
}

impl Session {
    const ANTHROPIC_API_VERSION: &'static str = "2023-06-01";
    const MAXIMUM_ENTITY_PROMPT_COUNT: usize = 100;
    const MAXIMUM_RESPONSE_BYTES: usize = 16 * 1024 * 1024;

    /// Swift's initializer with every argument explicit.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: Option<String>,
        config: SessionConfig,
        workflow_context: Option<WorkflowContext>,
        max_history_turns: Option<usize>,
        initial_world_view: Option<WorldView>,
        capability_registry: Option<CapabilityRegistry>,
        plugin_capability_executor: Option<PluginCapabilityExecutor>,
        plugin_query_snapshot_provider: Option<PluginQuerySnapshotProvider>,
        tool_policy: Option<ToolPolicy>,
    ) -> Self {
        let registry = capability_registry.unwrap_or_else(CapabilityRegistry::default_registry);
        let mut workflow_scope = SessionWorkflowScope::new();
        workflow_scope.context = workflow_context;
        let client_config = ClientConfig {
            timeout: Duration::from_secs_f64(config.timeout_interval.max(0.0)),
            ..ClientConfig::default()
        };
        Self {
            id: id.unwrap_or_else(diffuse_kernel::codable::new_uuid),
            config,
            client: HttpClient::new(client_config),
            max_history_turns: max_history_turns.unwrap_or(40),
            state: Mutex::new(SessionState {
                world_view: initial_world_view.unwrap_or_default(),
                conversation_history: Vec::new(),
                workflow_scope,
                observation_bus: None,
                context_memory: None,
                cached_memory_view: Vec::new(),
                perception_service: None,
                current_locale: None,
                harness: SessionHarnessState::default(),
                capabilities: SessionCapabilityState::new(
                    registry,
                    plugin_capability_executor,
                    plugin_query_snapshot_provider,
                ),
                active_inference_id: None,
                project_tool_executor: None,
                tool_policy,
                component_description_provider: None,
            }),
        }
    }

    /// Swift's `init(config:)` defaults: generated id, 40 history turns, an
    /// empty world view, the built-in registry and no plugins or policy.
    pub fn with_defaults(config: SessionConfig) -> Self {
        Self::new(None, config, None, None, None, None, None, None, None)
    }

    pub fn config(&self) -> &SessionConfig {
        &self.config
    }

    fn state(&self) -> MutexGuard<'_, SessionState> {
        match self.state.lock() {
            Ok(state) => state,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    pub fn world_view(&self) -> WorldView {
        self.state().world_view.clone()
    }

    pub fn workflow_context(&self) -> Option<WorkflowContext> {
        self.state().workflow_scope.context.clone()
    }

    // MARK: - Capability authority

    /// Withdraw pending authority without losing the conversation or host context.
    pub fn replace_plugin_capabilities(
        &self,
        executor: Option<PluginCapabilityExecutor>,
        query_snapshot_provider: Option<PluginQuerySnapshotProvider>,
    ) {
        let previous_drafts = {
            let mut state = self.state();
            state.active_inference_id = None;
            let drafts = state.capabilities.drafts.clone();
            state
                .capabilities
                .replace(executor, query_snapshot_provider);
            drafts
        };
        previous_drafts.remove_all();
    }

    pub fn set_workflow_context(&self, context: Option<WorkflowContext>) {
        let (memory, revision) = {
            let mut state = self.state();
            if state.active_inference_id.is_some() {
                return;
            }
            state.workflow_scope.context = context.clone();
            (
                state.context_memory.clone(),
                state.world_view.scene_revision.unwrap_or(0),
            )
        };
        let Some(memory) = memory else {
            return;
        };
        match context {
            Some(context) => {
                let entry = ContextEntry::new(
                    EntryKind::WorkflowContext,
                    "session",
                    Self::workflow_payload(&context),
                )
                .with_id("workflow:active")
                .with_importance(0.5)
                .with_revision(revision);
                memory.upsert(entry);
            }
            None => memory.remove("workflow:active"),
        }
    }

    pub fn set_workflow_scope(&self, scope: SessionWorkflowScope) -> Result<(), SessionError> {
        let mut state = self.state();
        if state.active_inference_id.is_some() {
            return Err(SessionError::InferenceAlreadyRunning);
        }
        state.workflow_scope = scope;
        Ok(())
    }

    /// Hands the turn loop to a harness, or back to the built-in loop with
    /// `None`. Harness state survives turns while `id` stays the same.
    pub fn set_harness(
        &self,
        driver: Option<SessionHarness>,
        id: Option<String>,
    ) -> Result<(), SessionError> {
        let mut state = self.state();
        if state.active_inference_id.is_some() {
            return Err(SessionError::InferenceAlreadyRunning);
        }
        if id != state.harness.id {
            state.harness.state = None;
        }
        state.harness.harness = driver;
        state.harness.id = id;
        Ok(())
    }

    pub fn set_project_tool_executor(&self, executor: Option<ProjectToolExecutor>) {
        self.state().project_tool_executor = executor;
    }

    pub fn set_component_description_provider(
        &self,
        provider: Option<ComponentDescriptionProvider>,
    ) {
        self.state().component_description_provider = provider;
    }

    fn workflow_payload(context: &WorkflowContext) -> BTreeMap<String, String> {
        let mut payload: BTreeMap<String, String> = BTreeMap::new();
        match context {
            WorkflowContext::Workstation(context) => {
                payload.insert("kind".to_string(), context.domain.as_str().to_string());
            }
            WorkflowContext::Asset(context) => {
                payload.insert("kind".to_string(), "asset".to_string());
                payload.insert("intent".to_string(), context.intent.clone());
            }
            WorkflowContext::Game(context) => {
                payload.insert("kind".to_string(), "game".to_string());
                payload.insert(
                    "level_phase".to_string(),
                    context.level_phase.as_str().to_string(),
                );
                payload.insert("genre".to_string(), context.gameplay_intent.genre.clone());
                payload.insert(
                    "win_condition".to_string(),
                    context.gameplay_intent.win_condition.clone(),
                );
                payload.insert(
                    "target_experience".to_string(),
                    context.target_experience.clone(),
                );
                if !context.known_constraints.scripting_registry.is_empty() {
                    payload.insert(
                        "scripting_registry".to_string(),
                        context.known_constraints.scripting_registry.join(","),
                    );
                }
            }
            WorkflowContext::Film(context) => {
                payload.insert("kind".to_string(), "film".to_string());
                payload.insert(
                    "narrative_phase".to_string(),
                    context.narrative_phase.as_str().to_string(),
                );
                payload.insert(
                    "active_sequence".to_string(),
                    context.active_sequence_id.clone(),
                );
                if let Some(shot) = &context.active_shot_id {
                    payload.insert("active_shot".to_string(), shot.clone());
                }
                if let Some(intent) = &context.director_intent
                    && !intent.is_empty()
                {
                    payload.insert(
                        "director_intent".to_string(),
                        intent.chars().take(256).collect(),
                    );
                }
                if !context.locked_shot_ids.is_empty() {
                    payload.insert(
                        "locked_shots".to_string(),
                        context.locked_shot_ids.join(","),
                    );
                }
            }
        }
        payload
    }

    pub fn set_observation_bus(&self, bus: Option<Arc<ObservationBus>>) {
        self.state().observation_bus = bus;
    }

    pub fn set_context_memory(&self, store: Option<Arc<ContextMemoryStore>>) {
        self.state().context_memory = store;
    }

    pub fn set_perception_service(&self, service: Option<Arc<PerceptionService>>) {
        self.state().perception_service = service;
    }

    // MARK: - Perception

    /// Runs perception on `image_url`, applies the resulting inferred world
    /// events to the world view, and records a `sceneAnnotation` memory entry
    /// per observation when a store is configured.
    pub fn tag_entity(
        &self,
        ref_: &str,
        image_url: &Path,
        task: PerceptionTask,
        max_results: i64,
    ) -> Result<Vec<WorldEvent>, PerceptionRuntimeError> {
        let service = self.state().perception_service.clone();
        let Some(service) = service else {
            return Err(PerceptionRuntimeError::WorkerUnavailable(
                "no PerceptionService configured on this Session".to_string(),
            ));
        };
        let events = service.tag(ref_, image_url, task, max_results)?;
        let (memory, revision) = {
            let mut state = self.state();
            for event in &events {
                state.world_view.apply_event(event.clone());
            }
            (
                state.context_memory.clone(),
                state.world_view.scene_revision.unwrap_or(0),
            )
        };
        if let Some(memory) = memory {
            for event in &events {
                let WorldEvent::EntityInferredUpdated {
                    ref_,
                    property,
                    value,
                    confidence,
                    source,
                } = event
                else {
                    continue;
                };
                let mut payload: BTreeMap<String, String> = BTreeMap::new();
                payload.insert("property".to_string(), property.clone());
                payload.insert(
                    "value".to_string(),
                    Self::world_property_prompt_string(value),
                );
                payload.insert("confidence".to_string(), format!("{confidence:.3}"));
                payload.insert(
                    "source".to_string(),
                    source.clone().unwrap_or_else(|| "perception".to_string()),
                );
                let entry = ContextEntry::new(EntryKind::SceneAnnotation, ref_.clone(), payload)
                    .with_id(format!("percept:{ref_}:{property}"))
                    .with_importance(confidence.clamp(0.3, 0.9))
                    .with_revision(revision);
                memory.upsert(entry);
            }
        }
        Ok(events)
    }

    /// Swift's default arguments: classification, 5 results.
    pub fn tag_entity_default(
        &self,
        ref_: &str,
        image_url: &Path,
    ) -> Result<Vec<WorldEvent>, PerceptionRuntimeError> {
        self.tag_entity(ref_, image_url, PerceptionTask::Classification, 5)
    }

    // MARK: - Signal processing

    /// Runs inference on a natural-language, correction or reference-image
    /// signal and returns a proposal. `on_progress` receives partial summary
    /// text while it streams in.
    pub fn process(
        &self,
        signal: &Signal,
        on_progress: Option<&SessionProgressHandler>,
    ) -> Result<Proposal, SessionError> {
        let run_id = {
            let mut state = self.state();
            if state.active_inference_id.is_some() {
                return Err(SessionError::InferenceAlreadyRunning);
            }
            let run_id = diffuse_kernel::codable::new_uuid();
            state.active_inference_id = Some(run_id.clone());
            run_id
        };
        let result = self.process_signal(signal, &run_id, on_progress);
        {
            let mut state = self.state();
            if state.active_inference_id.as_deref() == Some(run_id.as_str()) {
                state.active_inference_id = None;
            }
        }
        result
    }

    pub fn process_with_defaults(&self, signal: &Signal) -> Result<Proposal, SessionError> {
        self.process(signal, None)
    }

    fn process_signal(
        &self,
        signal: &Signal,
        run_id: &str,
        on_progress: Option<&SessionProgressHandler>,
    ) -> Result<Proposal, SessionError> {
        match signal {
            Signal::NaturalLanguage { text, locale } => {
                self.process_natural_language(text, locale, run_id, on_progress)
            }
            Signal::UserCorrection {
                proposal_id,
                accepted_step_ids,
                rejected_step_ids,
            } => self.process_correction(
                proposal_id,
                accepted_step_ids,
                rejected_step_ids,
                run_id,
                on_progress,
            ),
            Signal::ReferenceImage { url, entity_ref } => {
                self.process_reference_image(url, entity_ref.as_deref(), run_id, on_progress)
            }
            other => Err(SessionError::UnsupportedSignal(other.kind().to_string())),
        }
    }

    fn process_natural_language(
        &self,
        text: &str,
        locale: &str,
        run_id: &str,
        on_progress: Option<&SessionProgressHandler>,
    ) -> Result<Proposal, SessionError> {
        {
            let mut state = self.state();
            if !locale.is_empty() {
                state.current_locale = Some(locale.to_string());
            }
            let effective_locale = if locale.is_empty() {
                state
                    .current_locale
                    .clone()
                    .unwrap_or_else(|| "en".to_string())
            } else {
                locale.to_string()
            };
            state.harness.request =
                SessionHarnessTurnRequest::new(text.to_string(), effective_locale);
        }
        self.record_turn(ConversationTurn::new(ConversationTurnKind::UserText(
            text.to_string(),
        )));
        let (plan, tool_use_id, input_json) = self.infer(run_id, on_progress)?;
        self.record_turn(ConversationTurn::new(
            ConversationTurnKind::AssistantToolCall {
                tool_use_id: tool_use_id.clone(),
                name: "execute_edit_plan".to_string(),
                input_json,
            },
        ));
        self.update_issue_memory(text, &plan);
        Ok(self.proposal_from_plan(text.to_string(), plan, tool_use_id))
    }

    /// Invalidate the active run. In-flight network I/O may finish, but its
    /// result can no longer create or submit drafts.
    pub fn cancel_active_run(&self) {
        let drafts = {
            let mut state = self.state();
            state.active_inference_id = None;
            state.capabilities.submitted_snapshot = None;
            state.capabilities.submitted_drafts.clear();
            state.capabilities.drafts.clone()
        };
        drafts.remove_all();
    }

    fn process_correction(
        &self,
        proposal_id: &str,
        accepted_step_ids: &[String],
        rejected_step_ids: &[String],
        run_id: &str,
        on_progress: Option<&SessionProgressHandler>,
    ) -> Result<Proposal, SessionError> {
        let call_turn = {
            let state = self.state();
            state
                .conversation_history
                .iter()
                .rev()
                .find(|turn| matches!(turn.kind, ConversationTurnKind::AssistantToolCall { .. }))
                .cloned()
        };
        let Some(call_turn) = call_turn else {
            return Err(SessionError::UnsupportedSignal(
                "userCorrection: no prior plan in history".to_string(),
            ));
        };
        let ConversationTurnKind::AssistantToolCall {
            tool_use_id,
            input_json,
            ..
        } = call_turn.kind.clone()
        else {
            unreachable!("filtered to assistant tool calls above");
        };

        let outcome_content = if rejected_step_ids.is_empty() {
            "All steps applied successfully.".to_string()
        } else if accepted_step_ids.is_empty() {
            "Plan rejected entirely. Please propose a different approach.".to_string()
        } else {
            format!(
                "Partial application. Accepted: [{}]. Rejected: [{}]. Revise the rejected steps.",
                accepted_step_ids.join(", "),
                rejected_step_ids.join(", ")
            )
        };
        self.record_turn(
            ConversationTurn::new(ConversationTurnKind::ToolResult {
                tool_use_id: tool_use_id.clone(),
                content: outcome_content,
            })
            .with_proposal_id(Some(proposal_id.to_string())),
        );

        if rejected_step_ids.is_empty() {
            let (revision, snapshot, drafts) = self.proposal_authority();
            return Ok(Proposal::with_options(
                diffuse_kernel::codable::new_uuid(),
                self.id.clone(),
                String::new(),
                SceneEditPlan::new("All steps accepted.".to_string(), None, Vec::new()),
                revision,
                None,
                1.0,
                TransactionApprovalPolicy::Automatic,
                SwiftDate::now(),
                tool_use_id,
                snapshot,
                drafts,
            ));
        }

        let memory = self.state().context_memory.clone();
        if let Some(memory) = memory {
            let mut payload: BTreeMap<String, String> = BTreeMap::new();
            payload.insert(
                "rejected_count".to_string(),
                rejected_step_ids.len().to_string(),
            );
            payload.insert("proposal_id".to_string(), proposal_id.to_string());
            if let Ok(plan) = serde_json::from_str::<SceneEditPlan>(&input_json) {
                payload.insert(
                    "plan_ops".to_string(),
                    plan.steps
                        .iter()
                        .map(|step| step.op.raw_value().to_string())
                        .collect::<Vec<String>>()
                        .join(","),
                );
                if !plan.summary.is_empty() {
                    payload.insert(
                        "plan_summary".to_string(),
                        plan.summary.chars().take(120).collect(),
                    );
                }
            }
            let entry = ContextEntry::new(EntryKind::UserPreference, "session", payload)
                .with_id(format!("pref:rejected:{proposal_id}"))
                .with_importance(0.7);
            memory.upsert(entry);
        }

        let (plan, new_tool_use_id, input_json) = self.infer(run_id, on_progress)?;
        self.record_turn(ConversationTurn::new(
            ConversationTurnKind::AssistantToolCall {
                tool_use_id: new_tool_use_id.clone(),
                name: "execute_edit_plan".to_string(),
                input_json,
            },
        ));
        Ok(self.proposal_from_plan(
            format!("Correction: {} step(s) to revise", rejected_step_ids.len()),
            plan,
            new_tool_use_id,
        ))
    }

    fn process_reference_image(
        &self,
        url: &str,
        entity_ref: Option<&str>,
        run_id: &str,
        on_progress: Option<&SessionProgressHandler>,
    ) -> Result<Proposal, SessionError> {
        let filename = Path::new(url)
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let user_message = match entity_ref {
            Some(reference) => format!(
                "I have attached a reference image (\"{filename}\") for entity {reference}. \
Perception has already run and inferred properties are visible in the scene entity list. \
Based on those inferred observations and the surrounding scene, produce a scene edit plan \
that names, organizes, or extends the entity appropriately. \
If the inferred properties do not suggest any useful edits, reply with an empty steps array \
and explain in the summary."
            ),
            None => format!(
                "I have provided a reference image (\"{filename}\") for scene creation. \
Perception has run and any inferred entity properties appear in the scene entity list. \
Based on those observations and the current scene context, produce a scene edit plan \
that populates or refines the scene to match the reference. \
If no actionable changes can be derived, reply with an empty steps array."
            ),
        };
        self.record_turn(ConversationTurn::new(ConversationTurnKind::UserText(
            user_message.clone(),
        )));
        let (plan, tool_use_id, input_json) = self.infer(run_id, on_progress)?;
        self.record_turn(ConversationTurn::new(
            ConversationTurnKind::AssistantToolCall {
                tool_use_id: tool_use_id.clone(),
                name: "execute_edit_plan".to_string(),
                input_json,
            },
        ));
        Ok(self.proposal_from_plan(user_message, plan, tool_use_id))
    }

    fn proposal_authority(
        &self,
    ) -> (
        Option<u64>,
        Option<CapabilityExposureSnapshot>,
        Vec<CapabilityInvocationDraft>,
    ) {
        let state = self.state();
        (
            state.world_view.scene_revision,
            state.capabilities.submitted_snapshot.clone(),
            state.capabilities.submitted_drafts.clone(),
        )
    }

    fn proposal_from_plan(
        &self,
        semantic_intent: String,
        plan: SceneEditPlan,
        tool_use_id: String,
    ) -> Proposal {
        let (revision, snapshot, drafts) = self.proposal_authority();
        let confidence = Self::confidence(&plan);
        let approval_policy = if self.config.auto_approve {
            TransactionApprovalPolicy::Automatic
        } else {
            TransactionApprovalPolicy::RequiresApproval
        };
        Proposal::with_options(
            diffuse_kernel::codable::new_uuid(),
            self.id.clone(),
            semantic_intent,
            plan.clone(),
            revision,
            plan.reasoning.clone(),
            confidence,
            approval_policy,
            SwiftDate::now(),
            tool_use_id,
            snapshot,
            drafts,
        )
    }

    // MARK: - Outcome recording

    /// Records the outcome of a tool call as a tool_result message.
    pub fn record_outcome(&self, tool_use_id: &str, content: &str, proposal_id: Option<&str>) {
        self.record_turn(
            ConversationTurn::new(ConversationTurnKind::ToolResult {
                tool_use_id: tool_use_id.to_string(),
                content: content.to_string(),
            })
            .with_proposal_id(proposal_id.map(str::to_string)),
        );
    }

    // MARK: - WorldView observation

    pub fn observe_snapshot(
        &self,
        snapshot: &crate::semantic::scene_semantic_snapshot::SceneSemanticSnapshot,
    ) {
        self.state().world_view.apply_snapshot(snapshot);
    }

    pub fn observe_event(&self, event: WorldEvent) {
        let memory = {
            let mut state = self.state();
            state.world_view.apply_event(event.clone());
            state.context_memory.clone()
        };
        if let Some(memory) = memory {
            memory.apply(&event);
        }
    }

    pub fn observe_events(&self, events: Vec<WorldEvent>) {
        let memory = {
            let mut state = self.state();
            for event in &events {
                state.world_view.apply_event(event.clone());
            }
            state.context_memory.clone()
        };
        if let Some(memory) = memory {
            memory.apply_events(&events);
        }
    }

    pub fn replace_world_view(&self, world_view: WorldView) {
        self.state().world_view = world_view;
    }

    pub fn world_view_snapshot(&self) -> WorldView {
        self.state().world_view.clone()
    }

    pub fn observe_edit_summary(
        &self,
        edit_summary: &str,
        revision: u64,
    ) -> Result<(), ContextMemoryError> {
        let memory = {
            let mut state = self.state();
            state
                .world_view
                .apply_edit_summary(edit_summary.to_string(), revision);
            state.context_memory.clone()
        };
        match memory {
            Some(memory) => memory.flush(),
            None => Ok(()),
        }
    }

    /// Persists the context memory store to disk when a storage URL exists.
    pub fn flush_context_memory(&self) -> Result<(), ContextMemoryError> {
        let memory = self.state().context_memory.clone();
        match memory {
            Some(memory) => memory.flush(),
            None => Ok(()),
        }
    }

    pub fn observe_selection_changed(&self, entity_refs: &[String]) {
        self.state()
            .world_view
            .apply_selection_changed(entity_refs.to_vec());
    }

    pub fn entity_record(&self, ref_: &str) -> Option<WorldEntityRecord> {
        self.state().world_view.entity_record(ref_).cloned()
    }

    // MARK: - Issue memory

    pub(crate) fn update_issue_memory(&self, intent: &str, plan: &SceneEditPlan) {
        let memory = self.state().context_memory.clone();
        let Some(memory) = memory else {
            return;
        };
        let key = Self::issue_key(intent);
        if plan.is_empty() {
            let reason = if plan.summary.is_empty() {
                "no steps produced".to_string()
            } else {
                plan.summary.clone()
            };
            let mut payload: BTreeMap<String, String> = BTreeMap::new();
            payload.insert(
                "intent".to_string(),
                intent.chars().take(256).collect::<String>(),
            );
            payload.insert("reason".to_string(), reason);
            let revision = self.state().world_view.scene_revision.unwrap_or(0);
            let entry = ContextEntry::new(EntryKind::IssueTracked, "session", payload)
                .with_id(key)
                .with_importance(0.6)
                .with_revision(revision);
            memory.upsert(entry);
        } else {
            memory.remove(&key);
        }
    }

    pub fn issue_key(intent: &str) -> String {
        let lowercased = intent.chars().take(48).collect::<String>().to_lowercase();
        let normalized: String = lowercased
            .chars()
            .filter(|character| u32::from(*character) < 128)
            .map(|character| {
                if character.is_alphanumeric() {
                    character
                } else {
                    '_'
                }
            })
            .collect();
        format!("issue:{normalized}")
    }

    // MARK: - History

    pub fn clear_history(&self) {
        self.record_session_summary();
        let mut state = self.state();
        state.conversation_history.clear();
        state.harness.state = None;
    }

    fn record_session_summary(&self) {
        let (memory, history, revision) = {
            let state = self.state();
            (
                state.context_memory.clone(),
                state.conversation_history.clone(),
                state.world_view.scene_revision.unwrap_or(0),
            )
        };
        let Some(memory) = memory else {
            return;
        };
        if history.is_empty() {
            return;
        }
        let intents: Vec<String> = history
            .iter()
            .filter_map(|turn| match &turn.kind {
                ConversationTurnKind::UserText(text) => {
                    Some(text.chars().take(120).collect::<String>())
                }
                _ => None,
            })
            .collect();
        if intents.is_empty() {
            return;
        }
        let mut payload: BTreeMap<String, String> = BTreeMap::new();
        payload.insert("turn_count".to_string(), history.len().to_string());
        payload.insert("intent_count".to_string(), intents.len().to_string());
        let tail = if intents.len() > 5 {
            &intents[intents.len() - 5..]
        } else {
            &intents[..]
        };
        payload.insert("last_intents".to_string(), tail.join(" | "));
        payload.insert("scene_revision".to_string(), revision.to_string());
        let entry = ContextEntry::new(EntryKind::SessionSummary, "session", payload)
            .with_id(format!("summary:{}", self.id))
            .with_importance(0.5)
            .with_revision(revision);
        memory.upsert(entry);
    }

    pub fn history_snapshot(&self) -> Vec<ConversationTurn> {
        self.state().conversation_history.clone()
    }

    // MARK: - Inference

    fn infer(
        &self,
        run_id: &str,
        on_progress: Option<&SessionProgressHandler>,
    ) -> Result<(SceneEditPlan, String, String), SessionError> {
        self.ensure_active(run_id)?;
        let drafts = {
            let mut state = self.state();
            state.capabilities.submitted_snapshot = None;
            state.capabilities.submitted_drafts.clear();
            state.capabilities.drafts.clone()
        };
        drafts.remove_all();
        let memory = self.state().context_memory.clone();
        if let Some(memory) = memory {
            let view = memory.symbolic_view(20);
            self.state().cached_memory_view = view;
        }
        let harness = self.state().harness.harness.clone();
        if let Some(driver) = harness {
            return self.infer_harness_loop(run_id, driver);
        }
        if let Some(on_progress) = on_progress {
            return self.infer_streaming_loop(run_id, on_progress);
        }
        self.infer_non_streaming_loop(run_id)
    }

    fn infer_non_streaming_loop(
        &self,
        run_id: &str,
    ) -> Result<(SceneEditPlan, String, String), SessionError> {
        let mut extra_messages: Vec<Value> = Vec::new();
        let mut find_calls_remaining = 3;
        let mut tool_calls_remaining = 24;
        let mut parameter_repairs_remaining = 2;
        let mut snapshot = self.initial_capability_snapshot();
        loop {
            self.ensure_active(run_id)?;
            if tool_calls_remaining == 0 {
                return Err(SessionError::NoPlanInResponse);
            }
            tool_calls_remaining -= 1;
            let body = self.request_body(&extra_messages, Some(&snapshot), None);
            let data = self.post(&body)?;
            self.ensure_active(run_id)?;
            let mut call = self.parse_raw_tool_call(&data)?;
            if call.name == "execute_edit_plan" || call.name == "find_entities" {
                match self.applying_tool_policy(&call) {
                    Ok(next) => call = next,
                    Err(error) => {
                        extra_messages.extend(self.tool_call_exchange_messages(
                            &call,
                            &self.tool_call_denied_result_json(&error.to_string()),
                        ));
                        continue;
                    }
                }
            }
            if call.name == "execute_edit_plan" {
                return self.decode_plan(&call);
            } else if call.name == "find_entities" {
                if find_calls_remaining == 0 {
                    return Err(SessionError::NoPlanInResponse);
                }
                find_calls_remaining -= 1;
                let result_json = {
                    let state = self.state();
                    self.find_entities_result(&state.world_view, &call.input)
                };
                extra_messages.extend(self.tool_call_exchange_messages(&call, &result_json));
            } else {
                match self.handle_capability_tool_call(&call, &snapshot) {
                    Ok(CapabilityToolHandling::Exchange {
                        result_json,
                        snapshot: next_snapshot,
                    }) => {
                        snapshot = next_snapshot;
                        extra_messages
                            .extend(self.tool_call_exchange_messages(&call, &result_json));
                    }
                    Ok(CapabilityToolHandling::Completed {
                        plan,
                        input_json,
                        snapshot: submitted_snapshot,
                    }) => {
                        self.state().capabilities.submitted_snapshot = Some(submitted_snapshot);
                        return Ok((plan, call.id, input_json));
                    }
                    Err(error) => {
                        let Some(result_json) = Self::repairable_tool_error_json(&error) else {
                            return Err(error);
                        };
                        if parameter_repairs_remaining == 0 {
                            return Err(error);
                        }
                        parameter_repairs_remaining -= 1;
                        extra_messages
                            .extend(self.tool_call_exchange_messages(&call, &result_json));
                    }
                }
            }
        }
    }

    /// The harness decides each step; the session calls the model and runs
    /// tools exactly as the built-in loop does.
    fn infer_harness_loop(
        &self,
        run_id: &str,
        driver: SessionHarness,
    ) -> Result<(SceneEditPlan, String, String), SessionError> {
        let mut extra_messages: Vec<Value> = Vec::new();
        let mut snapshot = self.initial_capability_snapshot();
        let mut observation: Option<SessionHarnessTurnObservation> = None;
        let mut model_call: Option<RawToolCall> = None;
        for step in 0..SessionHarnessStep::MAXIMUM_STEPS {
            self.ensure_active(run_id)?;
            let (state_value, request) = {
                let state = self.state();
                (state.harness.state.clone(), state.harness.request.clone())
            };
            let tools = self.harness_tools(&snapshot);
            let turn = SessionHarnessTurn::new(
                step as i64,
                state_value,
                request,
                tools,
                observation.clone(),
            );
            let next = driver(turn).map_err(|error| SessionError::Other(error.to_string()))?;
            self.ensure_active(run_id)?;
            if let Some(state_value) = next.state {
                self.state().harness.state = Some(state_value);
            }
            match next.action {
                SessionHarnessStepAction::Model {
                    instructions,
                    message,
                } => {
                    if let Some(message) = message {
                        extra_messages.push(json!({"role": "user", "content": message}));
                    }
                    self.state().harness.instructions = instructions.clone();
                    let body = self.request_body(
                        &extra_messages,
                        Some(&snapshot),
                        instructions.as_deref(),
                    );
                    let data = self.post(&body)?;
                    self.state().harness.instructions = None;
                    self.ensure_active(run_id)?;
                    let call = self.parse_raw_tool_call(&data)?;
                    observation = Some(SessionHarnessTurnObservation::Model(Self::harness_call(
                        &call,
                    )));
                    model_call = Some(call);
                }
                SessionHarnessStepAction::Tool(requested) => {
                    let mut call = model_call
                        .take()
                        .filter(|call| {
                            call.id == requested.id.clone().unwrap_or_default()
                                && call.name == requested.name
                        })
                        .unwrap_or_else(|| {
                            Self::raw_call(
                                &requested,
                                requested
                                    .id
                                    .clone()
                                    .unwrap_or_else(|| format!("harness-{step}")),
                            )
                        });
                    let result =
                        (|| -> Result<Option<(SceneEditPlan, String, String)>, SessionError> {
                            if call.name == "execute_edit_plan" || call.name == "find_entities" {
                                call = self.applying_tool_policy(&call)?;
                            }
                            if call.name == "execute_edit_plan" {
                                let (plan, tool_use_id, input_json) = self.decode_plan(&call)?;
                                return Ok(Some((plan, tool_use_id, input_json)));
                            }
                            let result_json = if call.name == "find_entities" {
                                let state = self.state();
                                self.find_entities_result(&state.world_view, &call.input)
                            } else {
                                match self.handle_capability_tool_call(&call, &snapshot)? {
                                    CapabilityToolHandling::Exchange {
                                        result_json,
                                        snapshot: next_snapshot,
                                    } => {
                                        snapshot = next_snapshot;
                                        result_json
                                    }
                                    CapabilityToolHandling::Completed {
                                        plan,
                                        input_json,
                                        snapshot: submitted_snapshot,
                                    } => {
                                        self.state().capabilities.submitted_snapshot =
                                            Some(submitted_snapshot);
                                        return Ok(Some((plan, call.id.clone(), input_json)));
                                    }
                                }
                            };
                            extra_messages
                                .extend(self.tool_call_exchange_messages(&call, &result_json));
                            observation = Some(SessionHarnessTurnObservation::Tool(
                                Self::harness_call(&call),
                                Self::json_from_text(&result_json),
                            ));
                            Ok(None)
                        })();
                    match result {
                        Ok(Some(completed)) => return Ok(completed),
                        Ok(None) => {}
                        Err(SessionError::InferenceCancelled) => {
                            return Err(SessionError::InferenceCancelled);
                        }
                        Err(error) => {
                            let result_json = Self::repairable_tool_error_json(&error)
                                .unwrap_or_else(|| {
                                    self.tool_call_denied_result_json(&error.to_string())
                                });
                            extra_messages
                                .extend(self.tool_call_exchange_messages(&call, &result_json));
                            observation =
                                Some(SessionHarnessTurnObservation::Failure(error.to_string()));
                        }
                    }
                }
                SessionHarnessStepAction::Finish { summary } => {
                    let has_pending = self.state().capabilities.drafts.has_pending_drafts();
                    if has_pending {
                        observation = Some(SessionHarnessTurnObservation::Failure(
                            "Submit pending scene drafts with submit_plan before finishing."
                                .to_string(),
                        ));
                        continue;
                    }
                    let plan = SceneEditPlan::new(summary, None, Vec::new());
                    let input_json = serde_json::to_string(&plan)
                        .map_err(|error| SessionError::Other(error.to_string()))?;
                    return Ok((plan, format!("harness-finish-{step}"), input_json));
                }
            }
        }
        Err(SessionError::NoPlanInResponse)
    }

    /// The tools this turn may use, as a harness reads them.
    fn harness_tools(&self, snapshot: &CapabilityExposureSnapshot) -> Vec<SessionHarnessTurnTool> {
        let (registry, has_executor, allowed_names) = {
            let state = self.state();
            (
                state.capabilities.registry.clone(),
                state.project_tool_executor.is_some(),
                state.workflow_scope.allowed_project_tool_names.clone(),
            )
        };
        let mut definitions = CapabilityToolset::anthropic_tools(snapshot, &registry);
        if has_executor {
            definitions.extend(ProjectToolset::provider_definitions(
                SessionApiFormat::Anthropic,
                allowed_names.as_ref(),
            ));
        }
        definitions
            .into_iter()
            .filter_map(|definition| {
                let name = definition.get("name").and_then(Value::as_str)?;
                let description = definition
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let input_schema = definition
                    .get("input_schema")
                    .map(PluginJSON::from_foundation_value);
                Some(
                    SessionHarnessTurnTool::new(name.to_string(), description.to_string())
                        .with_input_schema(input_schema),
                )
            })
            .collect()
    }

    fn harness_call(call: &RawToolCall) -> SessionHarnessTurnCall {
        SessionHarnessTurnCall::new(call.name.clone())
            .with_id(Some(call.id.clone()))
            .with_arguments(Some(Self::json_from_text(&call.input_json)))
    }

    fn raw_call(call: &SessionHarnessTurnCall, id: String) -> RawToolCall {
        let value = call
            .arguments
            .as_ref()
            .map(PluginJSON::foundation_value)
            .unwrap_or_else(|| json!({}));
        let input_json = serde_json::to_string(&value).unwrap_or_else(|_| "{}".to_string());
        let input = match &value {
            Value::Object(map) => map.clone(),
            _ => Map::new(),
        };
        RawToolCall {
            name: call.name.clone(),
            id,
            input_json,
            input,
        }
    }

    /// Tool results are JSON text; anything else reaches the harness as a string.
    fn json_from_text(text: &str) -> PluginJSON {
        serde_json::from_str::<PluginJSON>(text)
            .unwrap_or_else(|_| PluginJSON::String(text.to_string()))
    }

    fn infer_streaming_loop(
        &self,
        run_id: &str,
        on_progress: &SessionProgressHandler,
    ) -> Result<(SceneEditPlan, String, String), SessionError> {
        let mut extra_messages: Vec<Value> = Vec::new();
        let mut find_calls_remaining = 3;
        let mut tool_calls_remaining = 24;
        let mut parameter_repairs_remaining = 2;
        let mut snapshot = self.initial_capability_snapshot();
        loop {
            self.ensure_active(run_id)?;
            if tool_calls_remaining == 0 {
                return Err(SessionError::NoPlanInResponse);
            }
            tool_calls_remaining -= 1;
            let mut call = self.stream_one_turn(&extra_messages, &snapshot, on_progress)?;
            self.ensure_active(run_id)?;
            if call.name == "execute_edit_plan" || call.name == "find_entities" {
                match self.applying_tool_policy(&call) {
                    Ok(next) => call = next,
                    Err(error) => {
                        extra_messages.extend(self.tool_call_exchange_messages(
                            &call,
                            &self.tool_call_denied_result_json(&error.to_string()),
                        ));
                        continue;
                    }
                }
            }
            if call.name == "execute_edit_plan" {
                return self.decode_plan(&call);
            } else if call.name == "find_entities" {
                if find_calls_remaining == 0 {
                    return Err(SessionError::NoPlanInResponse);
                }
                find_calls_remaining -= 1;
                let result_json = {
                    let state = self.state();
                    self.find_entities_result(&state.world_view, &call.input)
                };
                extra_messages.extend(self.tool_call_exchange_messages(&call, &result_json));
            } else {
                match self.handle_capability_tool_call(&call, &snapshot) {
                    Ok(CapabilityToolHandling::Exchange {
                        result_json,
                        snapshot: next_snapshot,
                    }) => {
                        snapshot = next_snapshot;
                        extra_messages
                            .extend(self.tool_call_exchange_messages(&call, &result_json));
                    }
                    Ok(CapabilityToolHandling::Completed {
                        plan,
                        input_json,
                        snapshot: submitted_snapshot,
                    }) => {
                        self.state().capabilities.submitted_snapshot = Some(submitted_snapshot);
                        return Ok((plan, call.id, input_json));
                    }
                    Err(error) => {
                        let Some(result_json) = Self::repairable_tool_error_json(&error) else {
                            return Err(error);
                        };
                        if parameter_repairs_remaining == 0 {
                            return Err(error);
                        }
                        parameter_repairs_remaining -= 1;
                        extra_messages
                            .extend(self.tool_call_exchange_messages(&call, &result_json));
                    }
                }
            }
        }
    }

    fn stream_one_turn(
        &self,
        extra_messages: &[Value],
        snapshot: &CapabilityExposureSnapshot,
        on_progress: &SessionProgressHandler,
    ) -> Result<RawToolCall, SessionError> {
        let body = self.request_body(extra_messages, Some(snapshot), None);
        let response = self.send_streaming_request(&body)?;

        let mut tool_use_id = String::new();
        let mut tool_name = String::new();
        let mut input_json = String::new();
        let mut last_reported_summary = String::new();

        let reader = BufReader::new(response.into_body());
        for line in reader.lines() {
            let Ok(line) = line else {
                break;
            };
            let Some(payload) = line.strip_prefix("data: ") else {
                continue;
            };
            if payload == "[DONE]" {
                break;
            }
            let Ok(event) = serde_json::from_str::<Value>(payload) else {
                continue;
            };
            match self.config.api_format {
                SessionApiFormat::Anthropic => {
                    let event_type = event.get("type").and_then(Value::as_str).unwrap_or("");
                    let block = event.get("content_block");
                    if event_type == "content_block_start"
                        && block
                            .and_then(|block| block.get("type"))
                            .and_then(Value::as_str)
                            == Some("tool_use")
                        && let Some(id) = block
                            .and_then(|block| block.get("id"))
                            .and_then(Value::as_str)
                    {
                        tool_use_id = id.to_string();
                        tool_name = block
                            .and_then(|block| block.get("name"))
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string();
                    } else if event_type == "content_block_delta"
                        && let Some(delta) = event.get("delta")
                        && delta.get("type").and_then(Value::as_str) == Some("input_json_delta")
                        && let Some(fragment) = delta.get("partial_json").and_then(Value::as_str)
                    {
                        input_json.push_str(fragment);
                        if (tool_name == "execute_edit_plan"
                            || tool_name == CapabilityToolset::SUBMIT_TOOL_NAME)
                            && let Some(partial) = Self::extract_partial_summary(&input_json)
                            && partial != last_reported_summary
                        {
                            last_reported_summary = partial.clone();
                            on_progress(partial);
                        }
                    }
                }
                SessionApiFormat::OpenAiCompatible => {
                    if let Some(call) = event
                        .get("choices")
                        .and_then(Value::as_array)
                        .and_then(|choices| choices.first())
                        .and_then(|choice| choice.get("delta"))
                        .and_then(|delta| delta.get("tool_calls"))
                        .and_then(Value::as_array)
                        .and_then(|calls| calls.first())
                    {
                        if let Some(id) = call.get("id").and_then(Value::as_str)
                            && !id.is_empty()
                        {
                            tool_use_id = id.to_string();
                        }
                        if let Some(function) = call.get("function") {
                            if let Some(name) = function.get("name").and_then(Value::as_str)
                                && !name.is_empty()
                            {
                                tool_name = name.to_string();
                            }
                            if let Some(fragment) =
                                function.get("arguments").and_then(Value::as_str)
                            {
                                input_json.push_str(fragment);
                                if (tool_name == "execute_edit_plan"
                                    || tool_name == CapabilityToolset::SUBMIT_TOOL_NAME)
                                    && let Some(partial) =
                                        Self::extract_partial_summary(&input_json)
                                    && partial != last_reported_summary
                                {
                                    last_reported_summary = partial.clone();
                                    on_progress(partial);
                                }
                            }
                        }
                    }
                }
                SessionApiFormat::OpenAiResponses => {
                    let event_type = event.get("type").and_then(Value::as_str).unwrap_or("");
                    if event_type == "response.output_item.added"
                        && let Some(item) = event.get("item")
                        && item.get("type").and_then(Value::as_str) == Some("function_call")
                    {
                        tool_use_id = item
                            .get("call_id")
                            .or_else(|| item.get("id"))
                            .and_then(Value::as_str)
                            .map(str::to_string)
                            .unwrap_or(tool_use_id);
                        tool_name = item
                            .get("name")
                            .and_then(Value::as_str)
                            .map(str::to_string)
                            .unwrap_or(tool_name);
                        if input_json.is_empty()
                            && let Some(arguments) = item.get("arguments").and_then(Value::as_str)
                        {
                            input_json = arguments.to_string();
                        }
                    } else if event_type == "response.function_call_arguments.delta"
                        && let Some(fragment) = event.get("delta").and_then(Value::as_str)
                    {
                        input_json.push_str(fragment);
                    } else if event_type == "response.output_item.done"
                        && input_json.is_empty()
                        && let Some(item) = event.get("item")
                        && item.get("type").and_then(Value::as_str) == Some("function_call")
                    {
                        tool_use_id = item
                            .get("call_id")
                            .or_else(|| item.get("id"))
                            .and_then(Value::as_str)
                            .map(str::to_string)
                            .unwrap_or(tool_use_id);
                        tool_name = item
                            .get("name")
                            .and_then(Value::as_str)
                            .map(str::to_string)
                            .unwrap_or(tool_name);
                        input_json = item
                            .get("arguments")
                            .and_then(Value::as_str)
                            .map(str::to_string)
                            .unwrap_or(input_json);
                    }
                    if (tool_name == "execute_edit_plan"
                        || tool_name == CapabilityToolset::SUBMIT_TOOL_NAME)
                        && let Some(partial) = Self::extract_partial_summary(&input_json)
                        && partial != last_reported_summary
                    {
                        last_reported_summary = partial.clone();
                        on_progress(partial);
                    }
                }
            }
        }

        if tool_use_id.is_empty() {
            return Err(SessionError::NoPlanInResponse);
        }
        let input = serde_json::from_str::<Value>(&input_json)
            .ok()
            .and_then(|value| match value {
                Value::Object(map) => Some(map),
                _ => None,
            })
            .unwrap_or_default();
        Ok(RawToolCall {
            name: tool_name,
            id: tool_use_id,
            input_json,
            input,
        })
    }

    fn ensure_active(&self, run_id: &str) -> Result<(), SessionError> {
        if self.state().active_inference_id.as_deref() != Some(run_id) {
            return Err(SessionError::InferenceCancelled);
        }
        Ok(())
    }

    fn extract_partial_summary(json: &str) -> Option<String> {
        let key = "\"summary\":\"";
        let start = json.find(key)? + key.len();
        let after = &json[start..];
        let mut result = String::new();
        let mut skip_next = false;
        for character in after.chars() {
            if skip_next {
                result.push(character);
                skip_next = false;
                continue;
            }
            if character == '\\' {
                skip_next = true;
                continue;
            }
            if character == '"' {
                break;
            }
            result.push(character);
        }
        if result.is_empty() {
            None
        } else {
            Some(result)
        }
    }

    fn request_body(
        &self,
        extra_messages: &[Value],
        snapshot: Option<&CapabilityExposureSnapshot>,
        harness_instructions: Option<&str>,
    ) -> Value {
        let snapshot = match snapshot {
            Some(snapshot) => snapshot.clone(),
            None => self.initial_capability_snapshot(),
        };
        let state = self.state();
        let mut all_messages = self.build_messages(&state);
        all_messages.extend(extra_messages.iter().cloned());
        let project_tools = if state.project_tool_executor.is_none() {
            Vec::new()
        } else {
            ProjectToolset::provider_definitions(
                self.config.api_format,
                state.workflow_scope.allowed_project_tool_names.as_ref(),
            )
        };
        let registry = &state.capabilities.registry;
        match self.config.api_format {
            SessionApiFormat::Anthropic => {
                let mut tools = CapabilityToolset::anthropic_tools(&snapshot, registry);
                tools.extend(project_tools);
                json!({
                    "model": self.config.model,
                    "max_tokens": self.config.max_tokens,
                    "system": self.system_prompt(&state, harness_instructions),
                    "tools": tools,
                    "tool_choice": {"type": "any"},
                    "messages": all_messages,
                })
            }
            SessionApiFormat::OpenAiCompatible => {
                let mut messages: Vec<Value> = vec![
                    json!({"role": "system", "content": self.system_prompt(&state, harness_instructions)}),
                ];
                messages.extend(all_messages);
                let mut tools = CapabilityToolset::open_ai_tools(&snapshot, registry);
                tools.extend(project_tools);
                json!({
                    "model": self.config.model,
                    "max_tokens": self.config.max_tokens,
                    "tools": tools,
                    "tool_choice": "required",
                    "messages": messages,
                })
            }
            SessionApiFormat::OpenAiResponses => {
                let mut tools = CapabilityToolset::open_ai_responses_tools(&snapshot, registry);
                tools.extend(project_tools);
                json!({
                    "model": self.config.model,
                    "max_output_tokens": self.config.max_tokens,
                    "instructions": self.system_prompt(&state, harness_instructions),
                    "tools": tools,
                    "tool_choice": "required",
                    "input": all_messages,
                })
            }
        }
    }

    fn build_messages(&self, state: &SessionState) -> Vec<Value> {
        let mut messages: Vec<Value> = Vec::new();
        for turn in &state.conversation_history {
            match &turn.kind {
                ConversationTurnKind::UserText(text) => {
                    messages.push(json!({"role": "user", "content": text}));
                }
                ConversationTurnKind::AssistantToolCall {
                    tool_use_id,
                    name,
                    input_json,
                } => match self.config.api_format {
                    SessionApiFormat::Anthropic => {
                        let input =
                            serde_json::from_str::<Value>(input_json).unwrap_or_else(|_| json!({}));
                        messages.push(json!({
                            "role": "assistant",
                            "content": [{
                                "type": "tool_use",
                                "id": tool_use_id,
                                "name": name,
                                "input": input,
                            }],
                        }));
                    }
                    SessionApiFormat::OpenAiCompatible => {
                        messages.push(json!({
                            "role": "assistant",
                            "content": Value::Null,
                            "tool_calls": [{
                                "id": tool_use_id,
                                "type": "function",
                                "function": {"name": name, "arguments": input_json},
                            }],
                        }));
                    }
                    SessionApiFormat::OpenAiResponses => {
                        messages.push(json!({
                            "type": "function_call",
                            "call_id": tool_use_id,
                            "name": name,
                            "arguments": input_json,
                        }));
                    }
                },
                ConversationTurnKind::ToolResult {
                    tool_use_id,
                    content,
                } => match self.config.api_format {
                    SessionApiFormat::Anthropic => {
                        messages.push(json!({
                            "role": "user",
                            "content": [{
                                "type": "tool_result",
                                "tool_use_id": tool_use_id,
                                "content": content,
                            }],
                        }));
                    }
                    SessionApiFormat::OpenAiCompatible => {
                        messages.push(json!({
                            "role": "tool",
                            "tool_call_id": tool_use_id,
                            "content": content,
                        }));
                    }
                    SessionApiFormat::OpenAiResponses => {
                        messages.push(json!({
                            "type": "function_call_output",
                            "call_id": tool_use_id,
                            "output": content,
                        }));
                    }
                },
            }
        }
        messages
    }

    fn system_prompt(&self, state: &SessionState, harness_instructions: Option<&str>) -> String {
        let mut parts: Vec<String> = vec![SESSION_INTRO.to_string()];
        if state.project_tool_executor.is_some() {
            parts.push(PROJECT_TOOLS_SECTION.to_string());
        }
        let agent = &state.workflow_scope.agent;
        if agent.includes(SessionContextSource::Scene) {
            let mut entity_section = format!(
                "Scene entities (JSON):\n{}",
                Self::entity_index_json(&state.world_view, &state.workflow_scope)
            );
            if let Some(note) = Self::entity_truncation_note(&state.world_view) {
                entity_section.push_str("\n\n");
                entity_section.push_str(&note);
            }
            parts.push(entity_section);
        }
        if agent.includes(SessionContextSource::Edits) && !state.world_view.recent_edits.is_empty()
        {
            let edits: Vec<&crate::context::world_view::WorldViewEdit> = state
                .world_view
                .recent_edits
                .iter()
                .rev()
                .take(10)
                .collect();
            let lines = edits
                .into_iter()
                .rev()
                .map(|edit| format!("- {} (rev {})", edit.summary, edit.revision))
                .collect::<Vec<String>>()
                .join("\n");
            parts.push(format!("Recent edits (most recent last):\n{lines}"));
        }
        if agent.includes(SessionContextSource::Memory)
            && !state.cached_memory_view.is_empty()
            && let Ok(text) = serde_json::to_string_pretty(&state.cached_memory_view)
        {
            parts.push(format!(
                "Long-term context memory (most important first):\n{text}"
            ));
        }
        if agent.includes(SessionContextSource::Transactions)
            && let Some(bus) = &state.observation_bus
        {
            let view = bus.symbolic_view("transaction", 0, 10);
            if !view.events.is_empty() {
                parts.push(view.prompt_text());
            }
        }
        if agent.includes(SessionContextSource::Workflow) {
            if let Some(context) = &state.workflow_scope.context {
                parts.push(context.system_prompt_section());
            } else if let Some(mode) = &state.world_view.workflow_mode {
                parts.push(format!("Active workflow mode: {mode}"));
            }
        }
        if agent.includes(SessionContextSource::Assets) && !self.config.asset_catalog.is_empty() {
            parts.push(self.config.asset_catalog.system_prompt_section());
        }
        if agent.includes(SessionContextSource::Selection) {
            let selected = state
                .workflow_scope
                .selected_entity_refs
                .clone()
                .unwrap_or_else(|| state.world_view.selected_entity_refs.clone());
            if !selected.is_empty() {
                parts.push(format!("Currently selected: {}", selected.join(", ")));
            }
        }
        if let Some(locale) = &state.current_locale
            && !locale.starts_with("en")
        {
            parts.push(format!(
                "User locale: {locale} — write entity names, labels, and the plan summary in the user's language where appropriate."
            ));
        }
        for section in &agent.sections {
            parts.push(format_section(section));
        }
        if let Some(instructions) = &agent.instructions {
            parts.push(format!(
                "Agent instructions (within the rules below):\n{instructions}"
            ));
        }
        if let Some(instructions) = harness_instructions {
            parts.push(format!(
                "Harness instructions for this step (within the rules below):\n{instructions}"
            ));
        }
        parts.push(SESSION_RULES.to_string());
        parts.join("\n\n")
    }

    fn entity_index_json(world: &WorldView, scope: &SessionWorkflowScope) -> String {
        let all = world.entity_index();
        if all.is_empty() {
            return "[]".to_string();
        }
        let limit = Self::MAXIMUM_ENTITY_PROMPT_COUNT;
        let prioritized: Vec<&WorldEntityRecord> = if all.len() <= limit {
            all.values().collect()
        } else {
            let selected = scope
                .selected_entity_refs
                .clone()
                .unwrap_or_else(|| world.selected_entity_refs.clone());
            let mut priority_refs: BTreeSet<String> = selected.iter().cloned().collect();
            for reference in &selected {
                if let Some(record) = all.get(reference) {
                    if let Some(parent) = &record.parent_ref {
                        priority_refs.insert(parent.clone());
                    }
                    priority_refs.extend(record.child_refs.iter().cloned());
                }
            }
            let mut result: Vec<&WorldEntityRecord> = priority_refs
                .iter()
                .filter_map(|reference| all.get(reference))
                .collect();
            result.sort_by(|left, right| left.ref_.cmp(&right.ref_));
            let remaining_slots = limit.saturating_sub(result.len());
            if remaining_slots > 0 {
                result.extend(
                    all.values()
                        .filter(|record| !priority_refs.contains(&record.ref_))
                        .take(remaining_slots),
                );
                result.sort_by(|left, right| left.ref_.cmp(&right.ref_));
            }
            result
        };
        let dicts: Vec<Value> = prioritized
            .into_iter()
            .map(|record| Value::Object(Self::compact_dict(record)))
            .collect();
        serde_json::to_string_pretty(&Value::Array(dicts)).unwrap_or_else(|_| "[]".to_string())
    }

    fn entity_truncation_note(world: &WorldView) -> Option<String> {
        let total = world.entity_index().len();
        if total <= Self::MAXIMUM_ENTITY_PROMPT_COUNT {
            return None;
        }
        Some(format!(
            "Note: scene has {total} entities; only {} are shown above (selected entities and their neighbours are prioritised). Use the scene.find_entities capability tool to search for entities by name or kind.",
            Self::MAXIMUM_ENTITY_PROMPT_COUNT
        ))
    }

    pub(crate) fn compact_dict(record: &WorldEntityRecord) -> Map<String, Value> {
        let mut dict = Map::new();
        dict.insert("ref".to_string(), Value::String(record.ref_.clone()));
        dict.insert("name".to_string(), Value::String(record.name.clone()));
        if let Some(value) = &record.kind {
            dict.insert("kind".to_string(), Value::String(value.clone()));
        }
        if !record.components.is_empty() {
            dict.insert(
                "components".to_string(),
                Value::Array(
                    record
                        .components
                        .iter()
                        .map(|value| Value::String(value.clone()))
                        .collect(),
                ),
            );
        }
        if let Some(value) = &record.parent_ref {
            dict.insert("parentRef".to_string(), Value::String(value.clone()));
        }
        if !record.child_refs.is_empty() {
            dict.insert(
                "childRefs".to_string(),
                Value::Array(
                    record
                        .child_refs
                        .iter()
                        .map(|value| Value::String(value.clone()))
                        .collect(),
                ),
            );
        }
        put_f32_vec(&mut dict, "position", &record.position);
        put_f32_vec(&mut dict, "scale", &record.scale);
        put_f32_vec(&mut dict, "eulerDegrees", &record.euler_degrees);
        if let Some(value) = &record.light_type {
            dict.insert("lightType".to_string(), Value::String(value.clone()));
        }
        put_f32(&mut dict, "lightIntensity", record.light_intensity);
        put_f32_vec(&mut dict, "lightColor", &record.light_color);
        put_f32(&mut dict, "lightRange", record.light_range);
        put_f32(&mut dict, "lightSpotInner", record.light_spot_inner);
        put_f32(&mut dict, "lightSpotOuter", record.light_spot_outer);
        put_bool(&mut dict, "lightCastShadows", record.light_cast_shadows);
        put_f32(&mut dict, "cameraFovYDegrees", record.camera_fov_y_degrees);
        put_bool(&mut dict, "cameraIsActive", record.camera_is_active);
        put_f32_vec(&mut dict, "meshColor", &record.mesh_color);
        put_f32_vec(&mut dict, "materialBaseColor", &record.material_base_color);
        put_f32(&mut dict, "materialMetallic", record.material_metallic);
        put_f32(&mut dict, "materialRoughness", record.material_roughness);
        put_f32_vec(&mut dict, "materialEmissive", &record.material_emissive);
        if let Some(value) = &record.rigid_body_motion_type {
            dict.insert(
                "rigidBodyMotionType".to_string(),
                Value::String(value.clone()),
            );
        }
        put_f32(&mut dict, "rigidBodyMass", record.rigid_body_mass);
        put_f32(
            &mut dict,
            "rigidBodyGravityScale",
            record.rigid_body_gravity_scale,
        );
        put_bool(
            &mut dict,
            "rigidBodyAllowSleep",
            record.rigid_body_allow_sleep,
        );
        if let Some(value) = &record.collider_shape {
            dict.insert("colliderShape".to_string(), Value::String(value.clone()));
        }
        put_f32_vec(
            &mut dict,
            "colliderBoxHalfExtents",
            &record.collider_box_half_extents,
        );
        put_f32(
            &mut dict,
            "colliderSphereRadius",
            record.collider_sphere_radius,
        );
        put_f32(
            &mut dict,
            "colliderCapsuleRadius",
            record.collider_capsule_radius,
        );
        put_f32(
            &mut dict,
            "colliderCapsuleHalfHeight",
            record.collider_capsule_half_height,
        );
        put_bool(&mut dict, "colliderIsTrigger", record.collider_is_trigger);
        put_f32(&mut dict, "colliderFriction", record.collider_friction);
        put_f32(
            &mut dict,
            "colliderRestitution",
            record.collider_restitution,
        );
        put_f32(&mut dict, "colliderDensity", record.collider_density);
        put_i64(&mut dict, "colliderLayerID", record.collider_layer_id);
        put_i64(&mut dict, "colliderLayerMask", record.collider_layer_mask);
        if let Some(value) = &record.audio_clip {
            dict.insert("audioClip".to_string(), Value::String(value.clone()));
        }
        put_f32(&mut dict, "audioVolume", record.audio_volume);
        put_bool(&mut dict, "audioLoop", record.audio_loop);
        put_bool(&mut dict, "audioPlayOnAwake", record.audio_play_on_awake);
        put_f32(&mut dict, "audioPitch", record.audio_pitch);
        put_f32(&mut dict, "audioSpatialBlend", record.audio_spatial_blend);
        if record.mesh_is_visible == Some(false) {
            dict.insert("meshIsVisible".to_string(), Value::Bool(false));
        }
        if let Some(value) = &record.animation_clip {
            dict.insert("animationClip".to_string(), Value::String(value.clone()));
        }
        put_f32(&mut dict, "animationSpeed", record.animation_speed);
        put_bool(&mut dict, "animationLoop", record.animation_loop);
        put_bool(&mut dict, "animationIsPlaying", record.animation_is_playing);
        put_bool(&mut dict, "constraintEnabled", record.constraint_enabled);
        if let Some(value) = &record.ragdoll_mode {
            dict.insert("ragdollMode".to_string(), Value::String(value.clone()));
        }
        put_f32(&mut dict, "ragdollBlendWeight", record.ragdoll_blend_weight);
        put_i64(&mut dict, "ragdollBoneCount", record.ragdoll_bone_count);
        put_i64(
            &mut dict,
            "ragdollSimulatedBoneCount",
            record.ragdoll_simulated_bone_count,
        );
        put_bool(&mut dict, "ragdollIsEnabled", record.ragdoll_is_enabled);
        if let Some(bindings) = &record.script_bindings
            && !bindings.is_empty()
        {
            let entries: Vec<Value> = bindings
                .iter()
                .map(|binding| {
                    let mut entry = Map::new();
                    entry.insert("handle".to_string(), Value::from(binding.handle));
                    entry.insert("enabled".to_string(), Value::Bool(binding.is_enabled));
                    if let Some(identifier) = &binding.identifier {
                        entry.insert("identifier".to_string(), Value::String(identifier.clone()));
                    }
                    if binding.parameters_json != "{}"
                        && !binding.parameters_json.is_empty()
                        && let Ok(parsed) = serde_json::from_str::<Value>(&binding.parameters_json)
                    {
                        entry.insert("params".to_string(), parsed);
                    }
                    Value::Object(entry)
                })
                .collect();
            dict.insert("scriptBindings".to_string(), Value::Array(entries));
        }
        if !record.evaluated.is_empty() {
            let mut evaluated = Map::new();
            for (key, value) in &record.evaluated {
                evaluated.insert(key.clone(), world_property_json_value(value));
            }
            dict.insert("evaluated".to_string(), Value::Object(evaluated));
        }
        if !record.inferred.is_empty() {
            let mut inferred = Map::new();
            for (key, property) in &record.inferred {
                let mut entry = Map::new();
                entry.insert(
                    "value".to_string(),
                    Value::String(property.display_value.clone()),
                );
                entry.insert("confidence".to_string(), number_value(property.confidence));
                if let Some(source) = &property.source {
                    entry.insert("source".to_string(), Value::String(source.clone()));
                }
                inferred.insert(key.clone(), Value::Object(entry));
            }
            dict.insert("inferred".to_string(), Value::Object(inferred));
        }
        dict
    }

    // MARK: - Confidence

    /// Derives a confidence score for a plan. Starts at 1.0 and applies the
    /// penalties and bonuses documented in the Swift implementation.
    pub fn confidence(plan: &SceneEditPlan) -> f64 {
        if plan.steps.is_empty() {
            return 1.0;
        }
        let mut score = 1.0;
        let mut affected: BTreeSet<String> = BTreeSet::new();
        let mut has_spawn = false;
        let mut has_delete = false;
        for (index, step) in plan.steps.iter().enumerate() {
            if index > 0 {
                score -= 0.03;
            }
            if step.op == SceneEditOp::DeleteEntity {
                score -= 0.10;
                has_delete = true;
            }
            if step.op == SceneEditOp::SpawnEntity {
                has_spawn = true;
            }
            if let Some(reference) = &step.entity_ref {
                affected.insert(reference.clone());
            }
        }
        let broad_penalty = affected.len().saturating_sub(5);
        score -= broad_penalty as f64 * 0.02;
        let spawn_needs_transform = plan
            .steps
            .iter()
            .any(|step| step.op == SceneEditOp::SpawnEntity && step.spawn_position.is_none());
        let has_transform = plan
            .steps
            .iter()
            .any(|step| step.op == SceneEditOp::SetTransform);
        if spawn_needs_transform && !has_transform {
            score -= 0.05;
        }
        if has_delete && !has_spawn {
            score -= 0.05;
        }
        if let Some(reasoning) = &plan.reasoning
            && !reasoning.trim().is_empty()
        {
            score = (score + 0.05).min(1.0);
        }
        score.max(0.40)
    }

    // MARK: - HTTP

    pub(crate) fn post(&self, body: &Value) -> Result<Vec<u8>, SessionError> {
        let request = self.make_inference_request(body, false)?;
        let policy = self.config.retry_policy;
        let mut attempt: usize = 0;
        loop {
            match self.client.send(request.clone()) {
                Ok(response) if (200..300).contains(&response.status) => {
                    return response
                        .bytes(Self::MAXIMUM_RESPONSE_BYTES)
                        .map_err(|error| SessionError::Other(error.to_string()));
                }
                Ok(response) => {
                    let status_code = i64::from(response.status);
                    let retry_after = Self::retry_after(&response);
                    let body_text = response
                        .bytes(Self::MAXIMUM_RESPONSE_BYTES)
                        .ok()
                        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned());
                    if RetryPolicy::is_retryable(status_code) && attempt < policy.max_retries {
                        self.backoff(&policy, attempt as i64, retry_after);
                        attempt += 1;
                        continue;
                    }
                    return Err(SessionError::HttpError {
                        status_code,
                        body: body_text,
                    });
                }
                Err(error @ (HttpError::Timeout | HttpError::Network(_))) => {
                    if attempt < policy.max_retries {
                        self.backoff(&policy, attempt as i64, None);
                        attempt += 1;
                        continue;
                    }
                    return Err(SessionError::Other(error.to_string()));
                }
                Err(error) => return Err(SessionError::Other(error.to_string())),
            }
        }
    }

    fn send_streaming_request(&self, body: &Value) -> Result<HttpResponse, SessionError> {
        let request = self.make_inference_request(body, true)?;
        let policy = self.config.retry_policy;
        let mut attempt: usize = 0;
        loop {
            match self.client.send(request.clone()) {
                Ok(response) if (200..300).contains(&response.status) => return Ok(response),
                Ok(response) => {
                    let status_code = i64::from(response.status);
                    let retry_after = Self::retry_after(&response);
                    let body_text = response
                        .bytes(Self::MAXIMUM_RESPONSE_BYTES)
                        .ok()
                        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned());
                    if RetryPolicy::is_retryable(status_code) && attempt < policy.max_retries {
                        self.backoff(&policy, attempt as i64, retry_after);
                        attempt += 1;
                        continue;
                    }
                    return Err(SessionError::HttpError {
                        status_code,
                        body: body_text,
                    });
                }
                Err(error @ (HttpError::Timeout | HttpError::Network(_))) => {
                    if attempt < policy.max_retries {
                        self.backoff(&policy, attempt as i64, None);
                        attempt += 1;
                        continue;
                    }
                    return Err(SessionError::Other(error.to_string()));
                }
                Err(error) => return Err(SessionError::Other(error.to_string())),
            }
        }
    }

    /// Builds the inference request shared by streaming and non-streaming paths.
    fn make_inference_request(
        &self,
        body: &Value,
        stream: bool,
    ) -> Result<HttpRequest, SessionError> {
        let mut body = body.clone();
        if stream && let Value::Object(map) = &mut body {
            map.insert("stream".to_string(), Value::Bool(true));
        }
        let base_url = self.config.base_url.trim_end_matches('/');
        let endpoint = match self.config.api_format {
            SessionApiFormat::Anthropic => format!("{base_url}/v1/messages"),
            SessionApiFormat::OpenAiResponses => format!("{base_url}/v1/responses"),
            SessionApiFormat::OpenAiCompatible => format!("{base_url}/v1/chat/completions"),
        };
        let bytes =
            serde_json::to_vec(&body).map_err(|error| SessionError::Other(error.to_string()))?;
        let mut request =
            HttpRequest::post(endpoint, bytes).header("Content-Type", "application/json");
        match self.config.api_format {
            SessionApiFormat::Anthropic => {
                request = request
                    .header("x-api-key", self.config.api_key.clone())
                    .header("anthropic-version", Self::ANTHROPIC_API_VERSION);
            }
            SessionApiFormat::OpenAiResponses | SessionApiFormat::OpenAiCompatible => {
                request =
                    request.header("Authorization", format!("Bearer {}", self.config.api_key));
            }
        }
        Ok(request)
    }

    fn backoff(&self, policy: &RetryPolicy, attempt: i64, retry_after: Option<f64>) {
        let random_unit = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| f64::from(duration.subsec_nanos()) / 1_000_000_000.0)
            .unwrap_or(0.5);
        let delay = policy.delay_with_random_unit(attempt, retry_after, random_unit);
        if delay > 0.0 {
            std::thread::sleep(Duration::from_secs_f64(delay));
        }
    }

    fn retry_after(response: &HttpResponse) -> Option<f64> {
        response
            .header("retry-after")
            .map(str::trim)
            .and_then(|value| value.parse::<f64>().ok())
    }

    // MARK: - Agentic loop helpers

    fn default_exposure_policy() -> CapabilityExposurePolicy {
        let mut policy = CapabilityExposurePolicy::new(ReleasePhase::Stable);
        policy.allowed_domains = Some(BTreeSet::from(["scene".to_string()]));
        policy.maximum_capabilities = 16;
        policy
    }

    fn initial_capability_snapshot(&self) -> CapabilityExposureSnapshot {
        let core_read_ids: BTreeSet<String> = [
            "scene.get_entities",
            "scene.get_selection",
            "scene.find_entities",
        ]
        .into_iter()
        .map(str::to_string)
        .collect();
        let preferred_ids: Vec<String> = core_read_ids.iter().cloned().collect();
        let mut state = self.state();
        state.capabilities.generation = state.capabilities.generation.wrapping_add(1);
        let generation = state.capabilities.generation;
        let base_policy = state
            .capabilities
            .executor
            .as_ref()
            .map(|executor| executor.exposure_policy())
            .unwrap_or_else(Self::default_exposure_policy);
        let restricted = state.workflow_scope.restricting(&base_policy);
        let revision = state.world_view.scene_revision.unwrap_or(0);
        let authorities = state
            .capabilities
            .executor
            .as_ref()
            .map(|executor| executor.plugin_authorities.clone())
            .unwrap_or_default();
        state.capabilities.registry.exposure_snapshot(
            &restricted,
            Some(revision),
            generation,
            &preferred_ids,
            Some(&core_read_ids),
            &authorities,
        )
    }

    fn handle_capability_tool_call(
        &self,
        call: &RawToolCall,
        snapshot: &CapabilityExposureSnapshot,
    ) -> Result<CapabilityToolHandling, SessionError> {
        let mut call = call.clone();
        let (revision, executor, workflow_scope, registry) = {
            let state = self.state();
            (
                state.world_view.scene_revision.unwrap_or(0),
                state.project_tool_executor.clone(),
                state.workflow_scope.clone(),
                state.capabilities.registry.clone(),
            )
        };

        if let Some(executor) = executor
            && let Some(tool) = ProjectToolset::definition(&call.name)
        {
            let value: Value = serde_json::from_str(&call.input_json)
                .map_err(|error| CapabilityDraftError::InvalidInput(error.to_string()))?;
            JsonSchemaValidator::validate(&value, &tool.schema)
                .map_err(|error| CapabilityDraftError::InvalidInput(error.to_string()))?;
            let drafts = self.state().capabilities.drafts.clone();
            if call.name == ProjectToolset::response_tool().name {
                if drafts.has_pending_drafts() {
                    return Err(CapabilityDraftError::InvalidInput(
                        "Use submit_plan for scene drafts.".to_string(),
                    )
                    .into());
                }
                let summary = call
                    .input
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let plan = SceneEditPlan::new(summary, None, Vec::new());
                let input_json = serde_json::to_string(&plan)
                    .map_err(|error| SessionError::decoding(error.to_string()))?;
                return Ok(CapabilityToolHandling::Completed {
                    plan,
                    input_json,
                    snapshot: snapshot.clone(),
                });
            }
            if ["save_scene", "export_project", "set_playback_state"].contains(&call.name.as_str())
                && drafts.has_pending_drafts()
            {
                return Err(CapabilityDraftError::InvalidInput(
                    "Submit pending scene drafts for review before saving, exporting or playing."
                        .to_string(),
                )
                .into());
            }
            if !workflow_scope
                .allowed_project_tool_names
                .as_ref()
                .is_none_or(|names| names.contains(&call.name))
            {
                return Err(CapabilityDraftError::UnknownTool(call.name.clone()).into());
            }
            let output = match executor(call.name.clone(), call.input_json.as_bytes().to_vec()) {
                Ok(output) => output,
                Err(error) => {
                    let message: String = error.to_string().chars().take(16_384).collect();
                    serde_json::to_vec(&json!({"ok": false, "error": message}))
                        .unwrap_or_else(|_| b"{}".to_vec())
                }
            };
            if output.len() > 524_288 || serde_json::from_slice::<Value>(&output).is_err() {
                return Err(SessionError::malformed(
                    "project tool returned an invalid or oversized result",
                ));
            }
            return Ok(CapabilityToolHandling::Exchange {
                result_json: String::from_utf8_lossy(&output).into_owned(),
                snapshot: snapshot.clone(),
            });
        }

        match self.applying_tool_policy(&call) {
            Ok(next) => call = next,
            Err(error) => {
                return Ok(CapabilityToolHandling::Exchange {
                    result_json: self.tool_call_denied_result_json(&error.to_string()),
                    snapshot: snapshot.clone(),
                });
            }
        }

        let contract: CapabilityContract = match call.name.as_str() {
            CapabilityToolset::SEARCH_TOOL_NAME => registry
                .descriptor("system.search_capabilities")
                .map(|descriptor| descriptor.contract())
                .ok_or_else(|| CapabilityDraftError::UnknownTool(call.name.clone()))?,
            CapabilityToolset::SUBMIT_TOOL_NAME => registry
                .descriptor("system.submit_plan")
                .map(|descriptor| descriptor.contract())
                .ok_or_else(|| CapabilityDraftError::UnknownTool(call.name.clone()))?,
            _ => snapshot
                .contract_for_tool_name(&call.name)
                .cloned()
                .ok_or_else(|| CapabilityDraftError::UnknownTool(call.name.clone()))?,
        };
        let value: Value = serde_json::from_str(&call.input_json)
            .map_err(|error| CapabilityDraftError::InvalidInput(error.to_string()))?;
        JsonSchemaValidator::validate(&value, &contract.input_schema)
            .map_err(|error| CapabilityDraftError::InvalidInput(error.to_string()))?;

        if call.name == CapabilityToolset::SEARCH_TOOL_NAME {
            return self.handle_search(&call, snapshot, revision);
        }

        if call.name == CapabilityToolset::SUBMIT_TOOL_NAME {
            return self.handle_submit(&call, snapshot, revision);
        }

        if contract.access == CapabilityAccess::Read {
            let executor = self.state().capabilities.executor.clone();
            if let (Some(plugin_id), Some(executor)) = (contract.source.plugin_id.clone(), executor)
            {
                let provider = self.state().capabilities.query_snapshot_provider.clone();
                let query_snapshot = match provider {
                    Some(provider) => provider(&plugin_id, revision)
                        .map_err(|error| SessionError::Other(error.to_string()))?,
                    None => None,
                };
                let payload = executor
                    .execute_read(
                        &call.name,
                        call.input_json.as_bytes(),
                        snapshot,
                        revision,
                        query_snapshot.as_ref(),
                    )
                    .map_err(SessionError::from)?;
                let value = String::from_utf8(payload.as_slice().to_vec()).map_err(|_| {
                    SessionError::Other(
                        PluginCapabilityExecutionFailure::Executor(
                            crate::tools::plugin_capability_executor::PluginCapabilityExecutorError::InvalidReadResult(
                                contract.id.clone(),
                            ),
                        )
                        .to_string(),
                    )
                })?;
                return Ok(CapabilityToolHandling::Exchange {
                    result_json: value,
                    snapshot: snapshot.clone(),
                });
            }
            let result = match contract.id.as_str() {
                "scene.describe_components" => {
                    let type_id = call.input.get("type_id").and_then(Value::as_str);
                    let provider = self.state().component_description_provider.clone();
                    let descriptions = match provider {
                        Some(provider) => provider(type_id),
                        None => SceneRuntime::new(ComponentRegistry::built_in())
                            .component_descriptions(type_id),
                    };
                    serde_json::to_string(&descriptions)
                        .map_err(|error| SessionError::malformed(error.to_string()))?
                }
                "scene.find_entities" => {
                    let state = self.state();
                    self.find_entities_result(&state.world_view, &call.input)
                }
                "scene.get_entities" => {
                    let state = self.state();
                    Self::entity_index_json(&state.world_view, &state.workflow_scope)
                }
                "scene.get_selection" => {
                    let state = self.state();
                    let selected = state
                        .workflow_scope
                        .selected_entity_refs
                        .clone()
                        .unwrap_or_else(|| state.world_view.selected_entity_refs.clone());
                    serde_json::to_string(&json!({ "selected": selected }))
                        .unwrap_or_else(|_| "{}".to_string())
                }
                _ => {
                    return Err(SessionError::malformed(format!(
                        "no read adapter is registered for {}",
                        contract.id
                    )));
                }
            };
            return Ok(CapabilityToolHandling::Exchange {
                result_json: result,
                snapshot: snapshot.clone(),
            });
        }

        let drafts = self.state().capabilities.drafts.clone();
        let draft = drafts.create_draft(
            &call.name,
            call.input_json.as_bytes(),
            snapshot,
            revision,
            CapabilitySwiftDate::now(),
        )?;
        let response = json!({
            "draft_id": draft.id,
            "capability_id": draft.capability_id,
            "status": "validated_not_applied",
        });
        let result_json = serde_json::to_string(&response)
            .map_err(|error| SessionError::malformed(error.to_string()))?;
        Ok(CapabilityToolHandling::Exchange {
            result_json,
            snapshot: snapshot.clone(),
        })
    }

    fn handle_search(
        &self,
        call: &RawToolCall,
        snapshot: &CapabilityExposureSnapshot,
        revision: u64,
    ) -> Result<CapabilityToolHandling, SessionError> {
        let query = call
            .input
            .get("query")
            .and_then(Value::as_str)
            .unwrap_or("");
        let domain = call.input.get("domain").and_then(Value::as_str);
        let requested_access = call
            .input
            .get("access")
            .and_then(Value::as_str)
            .and_then(|raw| {
                CapabilityAccess::ALL
                    .into_iter()
                    .find(|access| access.raw_value() == raw)
            });
        let (executor, workflow_scope, registry) = {
            let state = self.state();
            (
                state.capabilities.executor.clone(),
                state.workflow_scope.clone(),
                state.capabilities.registry.clone(),
            )
        };
        let unrestricted_policy = executor
            .as_ref()
            .map(|executor| executor.exposure_policy())
            .unwrap_or_else(Self::default_exposure_policy);
        let base_policy = workflow_scope.restricting(&unrestricted_policy);
        let mut policy = base_policy.clone();
        if let Some(domain) = domain {
            policy.allowed_domains = Some(match &base_policy.allowed_domains {
                Some(existing) => existing
                    .intersection(&BTreeSet::from([domain.to_string()]))
                    .cloned()
                    .collect(),
                None => BTreeSet::from([domain.to_string()]),
            });
        }
        policy.maximum_capabilities = 64;
        let authorities = executor
            .as_ref()
            .map(|executor| executor.plugin_authorities.clone())
            .unwrap_or_default();
        let mut candidates = registry.search_contracts(query, &policy, &authorities, 64);
        candidates.retain(|contract| !contract.id.starts_with("system."));
        if let Some(access) = requested_access {
            candidates.retain(|contract| contract.access == access);
        }
        let core_read_ids: BTreeSet<String> = [
            "scene.get_entities",
            "scene.get_selection",
            "scene.find_entities",
        ]
        .into_iter()
        .map(str::to_string)
        .collect();
        let existing_ids: Vec<String> = snapshot
            .contracts
            .iter()
            .map(|contract| contract.id.clone())
            .collect();
        let existing_set: BTreeSet<String> = existing_ids.iter().cloned().collect();
        let available = 16usize.saturating_sub(existing_ids.len());
        let additions: Vec<String> = candidates
            .iter()
            .filter(|contract| !existing_set.contains(&contract.id))
            .take(available)
            .map(|contract| contract.id.clone())
            .collect();
        let mut preferred_ids = existing_ids;
        preferred_ids.extend(additions);
        let mut included = core_read_ids;
        included.extend(preferred_ids.iter().cloned());
        let generation = {
            let mut state = self.state();
            state.capabilities.generation = state.capabilities.generation.wrapping_add(1);
            state.capabilities.generation
        };
        let mut next_snapshot = registry.exposure_snapshot(
            &base_policy,
            Some(revision),
            generation,
            &preferred_ids,
            Some(&included),
            &authorities,
        );
        // Searching expands the current authority set. Keeping the snapshot
        // identity means drafts created before a later search remain valid.
        next_snapshot.id = snapshot.id.clone();
        next_snapshot.created_at = snapshot.created_at;
        let activated: Vec<CapabilityContract> = candidates
            .into_iter()
            .filter(|contract| next_snapshot.contract(&contract.id).is_some())
            .collect();
        Ok(CapabilityToolHandling::Exchange {
            result_json: CapabilityToolset::search_result(&activated),
            snapshot: next_snapshot,
        })
    }

    fn handle_submit(
        &self,
        call: &RawToolCall,
        snapshot: &CapabilityExposureSnapshot,
        revision: u64,
    ) -> Result<CapabilityToolHandling, SessionError> {
        let summary = call
            .input
            .get("summary")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let reasoning = call
            .input
            .get("reasoning")
            .and_then(Value::as_str)
            .map(str::to_string);
        let raw_ids: Vec<Value> = call
            .input
            .get("draft_ids")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let ids: Vec<String> = raw_ids
            .iter()
            .filter_map(Value::as_str)
            .filter_map(Uuid::parse)
            .map(|uuid| uuid.as_str().to_string())
            .collect();
        if ids.len() != raw_ids.len() {
            return Err(SessionError::decoding(
                "submit_plan contains an invalid draft id",
            ));
        }
        let drafts = self.state().capabilities.drafts.clone();
        let validated =
            drafts.validated_drafts(&ids, snapshot, revision, CapabilitySwiftDate::now())?;
        self.state().capabilities.submitted_drafts = validated.clone();
        let built_in_drafts: Vec<CapabilityInvocationDraft> = validated
            .iter()
            .filter(|draft| draft.source_plugin_id.is_none())
            .cloned()
            .collect();
        let plan = if built_in_drafts.is_empty() {
            SceneEditPlan::new(summary, reasoning, Vec::new())
        } else {
            SceneCapabilityDraftLowering::plan(&summary, reasoning.as_deref(), &built_in_drafts)?
        };
        let input_json = serde_json::to_string(&plan)
            .map_err(|_| SessionError::decoding("could not encode submitted plan"))?;
        drafts.consume(&ids);
        Ok(CapabilityToolHandling::Completed {
            plan,
            input_json,
            snapshot: snapshot.clone(),
        })
    }

    fn repairable_tool_error_json(error: &SessionError) -> Option<String> {
        let SessionError::Draft(CapabilityDraftError::InvalidInput(reason)) = error else {
            return None;
        };
        serde_json::to_string(&json!({
            "error": "invalid_parameters",
            "detail": reason,
            "retryable": true,
            "repairs_remaining_are_host_limited": true,
        }))
        .ok()
    }

    /// Applies a policy rewrite to the call's argument payload.
    fn applying_tool_policy(&self, call: &RawToolCall) -> Result<RawToolCall, SessionError> {
        let policy = self.state().tool_policy.clone();
        let Some(policy) = policy else {
            return Ok(call.clone());
        };
        let evaluated = policy.evaluate(ToolCall::new(
            call.name.clone(),
            Data::from_bytes(call.input_json.as_bytes().to_vec()),
            ToolCallOrigin::AgentSession,
        ))?;
        Self::rebuilding_tool_call(call, evaluated.arguments.as_slice())
    }

    fn rebuilding_tool_call(
        call: &RawToolCall,
        arguments: &[u8],
    ) -> Result<RawToolCall, SessionError> {
        let input = serde_json::from_slice::<Value>(arguments)
            .ok()
            .and_then(|value| match value {
                Value::Object(map) => Some(map),
                _ => None,
            })
            .ok_or_else(|| {
                CapabilityDraftError::InvalidInput(
                    "tool policy arguments must be a JSON object".to_string(),
                )
            })?;
        Ok(RawToolCall {
            name: call.name.clone(),
            id: call.id.clone(),
            input_json: String::from_utf8_lossy(arguments).into_owned(),
            input,
        })
    }

    /// A denied tool call is an observation, not a session failure.
    fn tool_call_denied_result_json(&self, message: &str) -> String {
        serde_json::to_string(&json!({
            "ok": false,
            "error": format!("Tool call denied: {message}"),
        }))
        .unwrap_or_else(|_| r#"{"ok":false,"error":"tool call denied"}"#.to_string())
    }

    /// Parses a raw tool call from a non-streaming API response (either format).
    fn parse_raw_tool_call(&self, data: &[u8]) -> Result<RawToolCall, SessionError> {
        let json = serde_json::from_slice::<Value>(data)
            .map_err(|_| SessionError::malformed("top-level JSON is not an object"))?;
        if !json.is_object() {
            return Err(SessionError::malformed("top-level JSON is not an object"));
        }
        match self.config.api_format {
            SessionApiFormat::Anthropic => {
                let tool_use = json
                    .get("content")
                    .and_then(Value::as_array)
                    .and_then(|content| {
                        content.iter().find(|block| {
                            block.get("type").and_then(Value::as_str) == Some("tool_use")
                        })
                    })
                    .ok_or(SessionError::NoPlanInResponse)?;
                let id = tool_use
                    .get("id")
                    .and_then(Value::as_str)
                    .ok_or(SessionError::NoPlanInResponse)?;
                let name = tool_use
                    .get("name")
                    .and_then(Value::as_str)
                    .ok_or(SessionError::NoPlanInResponse)?;
                let input = tool_use
                    .get("input")
                    .and_then(Value::as_object)
                    .cloned()
                    .ok_or(SessionError::NoPlanInResponse)?;
                let input_json = serde_json::to_string(&Value::Object(input.clone()))
                    .unwrap_or_else(|_| "{}".to_string());
                Ok(RawToolCall {
                    name: name.to_string(),
                    id: id.to_string(),
                    input_json,
                    input,
                })
            }
            SessionApiFormat::OpenAiCompatible => {
                let message = json
                    .get("choices")
                    .and_then(Value::as_array)
                    .and_then(|choices| choices.first())
                    .and_then(|choice| choice.get("message"))
                    .ok_or(SessionError::NoPlanInResponse)?;
                let first_call = message
                    .get("tool_calls")
                    .and_then(Value::as_array)
                    .and_then(|calls| {
                        calls.iter().find(|call| {
                            call.get("type").and_then(Value::as_str) == Some("function")
                        })
                    })
                    .ok_or(SessionError::NoPlanInResponse)?;
                let id = first_call
                    .get("id")
                    .and_then(Value::as_str)
                    .ok_or(SessionError::NoPlanInResponse)?;
                let function = first_call
                    .get("function")
                    .ok_or(SessionError::NoPlanInResponse)?;
                let name = function
                    .get("name")
                    .and_then(Value::as_str)
                    .ok_or(SessionError::NoPlanInResponse)?;
                let args = function
                    .get("arguments")
                    .and_then(Value::as_str)
                    .ok_or(SessionError::NoPlanInResponse)?;
                let input = serde_json::from_str::<Value>(args)
                    .ok()
                    .and_then(|value| value.as_object().cloned())
                    .unwrap_or_default();
                Ok(RawToolCall {
                    name: name.to_string(),
                    id: id.to_string(),
                    input_json: args.to_string(),
                    input,
                })
            }
            SessionApiFormat::OpenAiResponses => {
                let call = json
                    .get("output")
                    .and_then(Value::as_array)
                    .and_then(|output| {
                        output.iter().find(|item| {
                            item.get("type").and_then(Value::as_str) == Some("function_call")
                        })
                    })
                    .ok_or(SessionError::NoPlanInResponse)?;
                let name = call
                    .get("name")
                    .and_then(Value::as_str)
                    .ok_or(SessionError::NoPlanInResponse)?;
                let args = call
                    .get("arguments")
                    .and_then(Value::as_str)
                    .ok_or(SessionError::NoPlanInResponse)?;
                let id = call
                    .get("call_id")
                    .or_else(|| call.get("id"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .unwrap_or_else(diffuse_kernel::codable::new_uuid);
                let input = serde_json::from_str::<Value>(args)
                    .ok()
                    .and_then(|value| value.as_object().cloned())
                    .unwrap_or_default();
                Ok(RawToolCall {
                    name: name.to_string(),
                    id,
                    input_json: args.to_string(),
                    input,
                })
            }
        }
    }

    /// Decodes a `SceneEditPlan` from a raw call that should be
    /// `execute_edit_plan`.
    fn decode_plan(
        &self,
        call: &RawToolCall,
    ) -> Result<(SceneEditPlan, String, String), SessionError> {
        let plan = serde_json::from_str::<SceneEditPlan>(&call.input_json)
            .map_err(|error| SessionError::decoding(error.to_string()))?;
        Ok((plan, call.id.clone(), call.input_json.clone()))
    }

    /// Searches the world view for the given name/kind/component/proximity query.
    pub(crate) fn find_entities_result(&self, world: &WorldView, input: &Map<String, Value>) -> String {
        let name_query = input
            .get("name")
            .and_then(Value::as_str)
            .map(str::to_lowercase);
        let kind_filter = input.get("kind").and_then(Value::as_str);
        let component_filter = input
            .get("component")
            .and_then(Value::as_str)
            .map(str::to_lowercase);
        let limit = input
            .get("limit")
            .and_then(Value::as_i64)
            .unwrap_or(20)
            .clamp(1, 200) as usize;
        let near_position = input
            .get("near_position")
            .and_then(Value::as_array)
            .and_then(|values| {
                let floats: Vec<f32> = values
                    .iter()
                    .filter_map(Value::as_f64)
                    .map(|value| value as f32)
                    .collect();
                if floats.len() >= 3 {
                    Some((floats[0], floats[1], floats[2]))
                } else {
                    None
                }
            });
        let near_radius = input
            .get("near_radius")
            .and_then(Value::as_f64)
            .map(|value| value as f32);

        let mut candidates: Vec<(&WorldEntityRecord, Option<f32>)> = Vec::new();
        for record in world.entity_index().values() {
            if let Some(query) = &name_query
                && !record.name.to_lowercase().contains(query)
            {
                continue;
            }
            if let Some(kind) = kind_filter
                && record.kind.as_deref() != Some(kind)
            {
                continue;
            }
            if let Some(component) = &component_filter
                && !record
                    .components
                    .iter()
                    .any(|candidate| candidate.to_lowercase() == *component)
            {
                continue;
            }
            let mut distance: Option<f32> = None;
            if let (Some(center), Some(radius)) = (near_position, near_radius) {
                let entity_position = match record.evaluated.get("worldPosition") {
                    Some(WorldPropertyValue::Vec3(x, y, z)) => Some((*x, *y, *z)),
                    _ => match &record.position {
                        Some(position) if position.len() >= 3 => {
                            Some((position[0], position[1], position[2]))
                        }
                        _ => None,
                    },
                };
                let Some(position) = entity_position else {
                    continue;
                };
                let dx = position.0 - center.0;
                let dy = position.1 - center.1;
                let dz = position.2 - center.2;
                let measured = (dx * dx + dy * dy + dz * dz).sqrt();
                if measured > radius {
                    continue;
                }
                distance = Some(measured);
            }
            candidates.push((record, distance));
        }
        if near_position.is_some() {
            candidates.sort_by(|left, right| {
                left.1
                    .unwrap_or(f32::INFINITY)
                    .total_cmp(&right.1.unwrap_or(f32::INFINITY))
            });
        }
        let mut results: Vec<Value> = Vec::new();
        for (record, distance) in candidates {
            results.push(Value::Object(Self::find_entity_entry(record, distance)));
            if results.len() >= limit {
                break;
            }
        }
        serde_json::to_string(&json!({
            "count": results.len(),
            "entities": results,
        }))
        .unwrap_or_else(|_| "{}".to_string())
    }

    fn find_entity_entry(record: &WorldEntityRecord, distance: Option<f32>) -> Map<String, Value> {
        let mut entry = Map::new();
        entry.insert("id".to_string(), Value::String(record.ref_.clone()));
        entry.insert("name".to_string(), Value::String(record.name.clone()));
        if let Some(value) = &record.kind {
            entry.insert("kind".to_string(), Value::String(value.clone()));
        }
        if !record.components.is_empty() {
            entry.insert(
                "components".to_string(),
                Value::Array(
                    record
                        .components
                        .iter()
                        .map(|value| Value::String(value.clone()))
                        .collect(),
                ),
            );
        }
        put_f32_vec(&mut entry, "position", &record.position);
        put_f32_vec(&mut entry, "eulerDegrees", &record.euler_degrees);
        put_f32_vec(&mut entry, "scale", &record.scale);
        if let Some(value) = record.evaluated.get("worldPosition") {
            entry.insert(
                "worldPosition".to_string(),
                world_property_json_value(value),
            );
        }
        if let Some(value) = record.evaluated.get("worldEulerDegrees") {
            entry.insert(
                "worldEulerDegrees".to_string(),
                world_property_json_value(value),
            );
        }
        if let Some(value) = record.evaluated.get("worldScale") {
            entry.insert("worldScale".to_string(), world_property_json_value(value));
        }
        if let Some(value) = &record.parent_ref {
            entry.insert("parentRef".to_string(), Value::String(value.clone()));
        }
        if let Some(value) = distance {
            entry.insert("distance".to_string(), Value::from(value));
        }
        if let Some(value) = &record.rigid_body_motion_type {
            entry.insert(
                "rigidBodyMotionType".to_string(),
                Value::String(value.clone()),
            );
        }
        put_f32(&mut entry, "rigidBodyMass", record.rigid_body_mass);
        put_f32(
            &mut entry,
            "rigidBodyGravityScale",
            record.rigid_body_gravity_scale,
        );
        put_bool(
            &mut entry,
            "rigidBodyAllowSleep",
            record.rigid_body_allow_sleep,
        );
        if let Some(value) = &record.collider_shape {
            entry.insert("colliderShape".to_string(), Value::String(value.clone()));
        }
        put_f32_vec(
            &mut entry,
            "colliderBoxHalfExtents",
            &record.collider_box_half_extents,
        );
        put_f32(
            &mut entry,
            "colliderSphereRadius",
            record.collider_sphere_radius,
        );
        put_f32(
            &mut entry,
            "colliderCapsuleRadius",
            record.collider_capsule_radius,
        );
        put_f32(
            &mut entry,
            "colliderCapsuleHalfHeight",
            record.collider_capsule_half_height,
        );
        put_bool(&mut entry, "colliderIsTrigger", record.collider_is_trigger);
        put_f32(&mut entry, "colliderFriction", record.collider_friction);
        put_f32(
            &mut entry,
            "colliderRestitution",
            record.collider_restitution,
        );
        put_i64(&mut entry, "colliderLayerID", record.collider_layer_id);
        put_i64(&mut entry, "colliderLayerMask", record.collider_layer_mask);
        if let Some(value) = &record.light_type {
            entry.insert("lightType".to_string(), Value::String(value.clone()));
        }
        put_f32(&mut entry, "lightIntensity", record.light_intensity);
        put_f32_vec(&mut entry, "lightColor", &record.light_color);
        put_f32(&mut entry, "lightRange", record.light_range);
        put_f32(&mut entry, "lightSpotInner", record.light_spot_inner);
        put_f32(&mut entry, "lightSpotOuter", record.light_spot_outer);
        put_bool(&mut entry, "lightCastShadows", record.light_cast_shadows);
        put_bool(&mut entry, "cameraIsActive", record.camera_is_active);
        put_f32(&mut entry, "cameraFovYDegrees", record.camera_fov_y_degrees);
        put_bool(&mut entry, "meshIsVisible", record.mesh_is_visible);
        put_f32_vec(&mut entry, "meshColor", &record.mesh_color);
        put_f32_vec(&mut entry, "materialBaseColor", &record.material_base_color);
        put_f32(&mut entry, "materialMetallic", record.material_metallic);
        put_f32(&mut entry, "materialRoughness", record.material_roughness);
        put_f32_vec(&mut entry, "materialEmissive", &record.material_emissive);
        if let Some(value) = &record.audio_clip {
            entry.insert("audioClip".to_string(), Value::String(value.clone()));
        }
        put_f32(&mut entry, "audioVolume", record.audio_volume);
        put_f32(&mut entry, "audioPitch", record.audio_pitch);
        put_bool(&mut entry, "audioLoop", record.audio_loop);
        put_bool(&mut entry, "audioPlayOnAwake", record.audio_play_on_awake);
        put_f32(&mut entry, "audioSpatialBlend", record.audio_spatial_blend);
        if let Some(value) = &record.animation_clip {
            entry.insert("animationClip".to_string(), Value::String(value.clone()));
        }
        put_f32(&mut entry, "animationSpeed", record.animation_speed);
        put_bool(&mut entry, "animationLoop", record.animation_loop);
        put_bool(
            &mut entry,
            "animationIsPlaying",
            record.animation_is_playing,
        );
        put_bool(&mut entry, "constraintEnabled", record.constraint_enabled);
        if let Some(value) = &record.ragdoll_mode {
            entry.insert("ragdollMode".to_string(), Value::String(value.clone()));
        }
        put_f32(
            &mut entry,
            "ragdollBlendWeight",
            record.ragdoll_blend_weight,
        );
        put_i64(&mut entry, "ragdollBoneCount", record.ragdoll_bone_count);
        put_i64(
            &mut entry,
            "ragdollSimulatedBoneCount",
            record.ragdoll_simulated_bone_count,
        );
        put_bool(&mut entry, "ragdollIsEnabled", record.ragdoll_is_enabled);
        if let Some(bindings) = &record.script_bindings
            && !bindings.is_empty()
        {
            let entries: Vec<Value> = bindings
                .iter()
                .map(|binding| {
                    let mut rec = Map::new();
                    rec.insert("handle".to_string(), Value::from(binding.handle));
                    rec.insert("enabled".to_string(), Value::Bool(binding.is_enabled));
                    if let Some(identifier) = &binding.identifier {
                        rec.insert("identifier".to_string(), Value::String(identifier.clone()));
                    }
                    if binding.parameters_json != "{}"
                        && !binding.parameters_json.is_empty()
                        && let Ok(parsed) = serde_json::from_str::<Value>(&binding.parameters_json)
                    {
                        rec.insert("params".to_string(), parsed);
                    }
                    Value::Object(rec)
                })
                .collect();
            entry.insert("scriptBindings".to_string(), Value::Array(entries));
        }
        entry
    }

    /// Builds the assistant tool-call message and tool-result message pair.
    fn tool_call_exchange_messages(&self, call: &RawToolCall, result_json: &str) -> Vec<Value> {
        match self.config.api_format {
            SessionApiFormat::Anthropic => vec![
                json!({
                    "role": "assistant",
                    "content": [{
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": Value::Object(call.input.clone()),
                    }],
                }),
                json!({
                    "role": "user",
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": call.id,
                        "content": result_json,
                    }],
                }),
            ],
            SessionApiFormat::OpenAiCompatible => vec![
                json!({
                    "role": "assistant",
                    "content": Value::Null,
                    "tool_calls": [{
                        "id": call.id,
                        "type": "function",
                        "function": {"name": call.name, "arguments": call.input_json},
                    }],
                }),
                json!({
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": result_json,
                }),
            ],
            SessionApiFormat::OpenAiResponses => vec![
                json!({
                    "type": "function_call",
                    "call_id": call.id,
                    "name": call.name,
                    "arguments": call.input_json,
                }),
                json!({
                    "type": "function_call_output",
                    "call_id": call.id,
                    "output": result_json,
                }),
            ],
        }
    }

    pub(crate) fn record_turn(&self, turn: ConversationTurn) {
        let mut state = self.state();
        state.conversation_history.push(turn);
        while state.conversation_history.len() > self.max_history_turns {
            if state.conversation_history.len() >= 3
                && matches!(
                    state.conversation_history[0].kind,
                    ConversationTurnKind::UserText(_)
                )
            {
                state.conversation_history.drain(0..3);
            } else {
                state.conversation_history.remove(0);
            }
        }
    }

    fn world_property_prompt_string(value: &WorldPropertyValue) -> String {
        match value {
            WorldPropertyValue::Json(component) => {
                serde_json::to_string(&component.to_json_value())
                    .unwrap_or_else(|_| "null".to_string())
            }
            WorldPropertyValue::Vec3(x, y, z) => format!(
                "[{}, {}, {}]",
                swift_float_text(*x),
                swift_float_text(*y),
                swift_float_text(*z)
            ),
            WorldPropertyValue::Vec4(x, y, z, w) => format!(
                "[{}, {}, {}, {}]",
                swift_float_text(*x),
                swift_float_text(*y),
                swift_float_text(*z),
                swift_float_text(*w)
            ),
            WorldPropertyValue::Float(number) => swift_float_text(*number),
            WorldPropertyValue::String(text) => text.clone(),
            WorldPropertyValue::Bool(flag) => flag.to_string(),
        }
    }
}

/// Swift `init(config:)` uses `UUID().uuidString`.
fn number_value(value: f64) -> Value {
    serde_json::Number::from_f64(value)
        .map(Value::Number)
        .unwrap_or(Value::Null)
}

fn swift_float_text(value: f32) -> String {
    let text = format_float(value).unwrap_or_else(|| "nan".to_string());
    if !text.contains('.') && !text.contains('e') && !text.contains('E') {
        format!("{text}.0")
    } else {
        text
    }
}

fn world_property_json_value(value: &WorldPropertyValue) -> Value {
    match value {
        WorldPropertyValue::Json(component) => component.to_json_value(),
        WorldPropertyValue::Vec3(x, y, z) => {
            json!([Value::from(*x), Value::from(*y), Value::from(*z)])
        }
        WorldPropertyValue::Vec4(x, y, z, w) => {
            json!([
                Value::from(*x),
                Value::from(*y),
                Value::from(*z),
                Value::from(*w)
            ])
        }
        WorldPropertyValue::Float(number) => Value::from(*number),
        WorldPropertyValue::String(text) => Value::String(text.clone()),
        WorldPropertyValue::Bool(flag) => Value::Bool(*flag),
    }
}

fn put_f32(map: &mut Map<String, Value>, key: &str, value: Option<f32>) {
    if let Some(value) = value {
        map.insert(key.to_string(), Value::from(value));
    }
}

fn put_f32_vec(map: &mut Map<String, Value>, key: &str, value: &Option<Vec<f32>>) {
    if let Some(values) = value {
        map.insert(
            key.to_string(),
            Value::Array(values.iter().map(|value| Value::from(*value)).collect()),
        );
    }
}

fn put_bool(map: &mut Map<String, Value>, key: &str, value: Option<bool>) {
    if let Some(value) = value {
        map.insert(key.to_string(), Value::Bool(value));
    }
}

fn put_i64(map: &mut Map<String, Value>, key: &str, value: Option<i64>) {
    if let Some(value) = value {
        map.insert(key.to_string(), Value::from(value));
    }
}

fn format_section(section: &SessionContextSection) -> String {
    format!("{}:\n{}", section.title, section.text)
}

const SESSION_INTRO: &str = "You are the AI scene-editing core of Cove, a native real-time game and cinematic engine.\n\
Discover needed abilities with `search_capabilities`, call the returned exact capability tools to create write drafts, then finish with `submit_plan` using the ordered draft IDs. Capability tool calls never apply writes directly. Finish scene edits with `submit_plan`. Always finish through a tool call; do not respond with unstructured plain text.";

const PROJECT_TOOLS_SECTION: &str = "Project tools are also available: inspect the project and scripting API, read/write Swift sources, compile them, inspect diagnostics, save, export and control playback. These host workspace operations return their actual result; do not claim success without checking it. Never grant script trust yourself. Read before overwriting and use the returned source hash. Scene changes still require capability drafts and review. For answers or completed project-only work, finish with `respond`. For scene changes, finish with `submit_plan`. Do not save or export unapplied drafts.";

const SESSION_RULES: &str = concat!(
    "Rules:\n",
    "- Only operate on entities that exist in the scene entities list above.\n",
    "- Use the exact entity IDs from the list (format: \"scene:<number>\").\n",
    "- Prefer minimal plans — only include steps necessary to satisfy the request.\n",
    "- When \"Currently selected\" is non-empty, treat those entities as the user's primary target for any ambiguous request (e.g. \"make it bigger\", \"delete it\", \"change the colour\"). Only operate on non-selected entities when the request clearly names or describes them.\n",
    "- For duplicate_entity: use `duplicate_offset` ([dx, dy, dz]) to place the copy offset from the source in local space (e.g. [2,0,0] to place it 2 m to the right). Without duplicate_offset, the copy lands on top of the source. Always provide an offset when the user's request implies a different location (\"add another one next to it\").\n",
    "- For reparent_entity: moving an entity to a new parent changes its local transform relative to that parent. After reparenting, follow up with set_transform if the entity's world position should be preserved.\n",
    "- For set_transform, use the `position`, `scale`, and `eulerDegrees` fields (all local space) as the base and only change what the user asked for. When an entity is in a hierarchy, `evaluated.worldPosition` shows its actual world-space position, `evaluated.worldEulerDegrees` shows world-space rotation, and `evaluated.worldScale` shows the cumulative world-space scale — use these for spatial reasoning, but set_transform always writes local space. For root-level entities (parentRef absent), local space equals world space so you can use worldPosition values directly.\n",
    "- The `scale` field is omitted when uniform [1, 1, 1]; treat missing `scale` as [1, 1, 1].\n",
    "- The `eulerDegrees` field is omitted when the rotation is [0, 0, 0]; treat missing `eulerDegrees` as [0, 0, 0]. Angles are XYZ intrinsic Euler in degrees.\n",
    "- For spawn_entity: use `spawn_kind` to choose the entity type — \"mesh\" (default, creates a Static Mesh), \"empty\" (bare group/parent node with no components), \"light\" (creates a light; combine with `light_type` for directional/point/spot; use `intensity`, `color`, `range`, and `cast_shadows` in the SAME step to set initial values — these are applied atomically at creation and you do NOT need follow-up set_light_* steps for them), \"camera\" (creates an inactive camera; use `camera_fov_y` in the same step to set initial field of view). Use `spawn_parent_id` (\"scene:<number>\") in the same step to make the new entity a child of an existing entity — this avoids a separate reparent_entity step. When creating a group, use spawn_kind \"empty\" with the desired parent in spawn_parent_id.\n",
    "- For snap_to_ground, set Y position to 0.\n",
    "- For set_camera_fov: use `camera_fov_y` (degrees, 1–179). 30≈telephoto, 50≈normal, 75≈wide.\n",
    "- For set_camera_active: use `camera_is_active` (boolean). Only one camera should be active at a time.\n",
    "- Each entity may have an `inferred` dict with AI perception observations (e.g. object category, semantic role). Use high-confidence (≥0.8) inferred properties to understand what the entity represents in the real world when naming, grouping, or describing it.\n",
    "- If the previous tool_result shows the user rejected your plan, adjust your approach.\n",
    "- For set_script_property: use `script_property_name` (the parameter key) and `script_property_value` (the new value — string, number, boolean, or array). The entity's `scriptBindings` shows existing scripts and their current `params`. Use `script_index` (default 0) to target a specific binding when an entity has multiple scripts. Provide `script_identifier` with a stable catalog ID to create or replace a binding.\n",
    "- For set_script_enabled: use `is_enabled` (true/false) and `script_index` (default 0) to enable or disable a specific script binding on the entity; `script_identifier` can create or replace that binding.\n",
    "- For set_collider_layer: use `collider_layer_id` (0–15, which layer the collider occupies) and/or `collider_layer_mask` (bitmask of layers this collider interacts with, e.g. 0xFFFF = collide with all layers). An entity's `colliderLayerID` and `colliderLayerMask` fields show the current values.\n",
    "- Collider dimensions are shown in `colliderBoxHalfExtents` ([x,y,z] half-sizes in metres for box colliders), `colliderSphereRadius` (sphere radius in metres), `colliderCapsuleRadius` and `colliderCapsuleHalfHeight` (capsule dimensions in metres). Use these when resizing or comparing physical bounds.\n",
    "- For set_material: use `material_base_color` ([r,g,b,a] linear 0–1), `material_metallic` (0–1; 0=dielectric, 1=full metal), `material_roughness` (0–1; 0=mirror-smooth, 1=fully rough), and `material_emissive` ([r,g,b] linear 0–1; omit for no change). Omitting any field preserves the entity's current value — only include fields you want to change. An entity's `materialBaseColor`, `materialMetallic`, `materialRoughness`, and `materialEmissive` fields show the current PBR values when non-default. Prefer set_material over set_mesh_color for precise or multi-channel appearance control; use set_mesh_color only for a simple RGB tint when no PBR properties are needed.\n",
    "- If the user asks a general question rather than requesting a scene change, call submit_plan with an empty draft_ids array and put the reply in summary.\n",
    "- For set_audio_source: `audio_pitch` (1.0=normal, 2.0=one octave up, 0.5=one octave down) and `audio_spatial_blend` (0=fully 2D, 1=fully 3D positional) are shown in `audioPitch` and `audioSpatialBlend` only when non-default (pitch≠1.0 or blend>0). Omitting any field preserves the current value.\n",
    "- Discover scene.describe_components to inspect registered component fields, dependencies and authored defaults. Field paths refer to stored component JSON; numeric presentation scales describe inspector display units. Use exact write capability contracts for changes.\n",
    "- Use the scene.find_entities read capability (name substring, kind, component, or spatial proximity) to locate entities whose IDs are not visible in the scene list. The `component` parameter accepts tags like \"light\", \"camera\", \"rigidbody\", \"collider\", \"audio_source\", \"animation\", \"script\", \"constraint\". Use `near_position` + `near_radius` (metres) to find entities near a given world-space point (e.g. to select all lights near the player spawn). After it returns, call exact write capability tools with the discovered IDs, then submit_plan."
);
