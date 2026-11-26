//! `Editor/Sources/EditorCore/Application/AI/AISettings.swift`.
//!
//! Swift chains the session hot-swap through `Task`; there is no async runtime
//! here, so the same steps run inline in the order Swift awaits them (§5.5).

use std::collections::BTreeMap;
use std::rc::Rc;

use diffuse_ai::context::workflow_context::{GameKnownConstraints, GameplayIntent, ScriptSchema};
use diffuse_ai::context::workflow_context::{GameWorkflowContext, WorkflowContext};
use diffuse_ai::context::workstation_context::{WorkstationContext, WorkstationContextDomain};
use diffuse_ai::session::session::Session;
use diffuse_ai::session::session_config::SessionConfig;
use diffuse_ai::tools::project_toolset::Executor as ProjectToolExecutor;
use diffuse_ai::tools::tool_policy::ToolCallOrigin;
use diffuse_ai::tools::tool_policy::ToolPolicy;
use diffuse_capability::contracts::exports::SessionApiFormat;
use diffuse_capability::release::release_phase_gate::ReleasePhaseGate;
use diffuse_intent::BuiltInTypedCapabilityCatalog;
use diffuse_intent::invocation::ambiguity_scorer::AmbiguityScorer;
use diffuse_intent::invocation::capability_invocation_planning::CapabilityInvocationPlanner;

use crate::ai::chat::ai_chat_message::AIChatAssistantState;
use crate::ai::chat::editor_ai_settings::{
    AICredentialSource, AICredentialStore, EditorAISettings, EditorCapabilitySettings,
};
use crate::ai::chat::editor_agent_task_service::EditorAgentTaskPhase;
use crate::ai::editor_project_tools::EditorProjectToolError;
use crate::application::editor_application::{EditorApplication, SendableAppHandle};
use crate::contributions::ai_providers::{AIProviderCatalog, AIProviderDescriptor};
use crate::scripting::dynamic::project_script_catalog::ProjectScriptCatalogEntry;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{EditorConsoleSeverity, PlaybackState};
use crate::state::workspace::content::EditorContent;

impl EditorApplication {
    /// `applyAISettings(_:credentials:)` — persists provider/model/agent, writes
    /// the entered auth values to the credential file, and hot-swaps the session.
    pub fn apply_ai_settings(
        self: &Rc<Self>,
        settings: &EditorAISettings,
        credentials: &BTreeMap<String, String>,
    ) -> bool {
        let providers = self.ai_provider_catalog();
        let provider = providers.provider(&settings.provider_id).cloned();
        let entered: BTreeMap<String, String> = credentials
            .iter()
            .filter(|(_, value)| !value.is_empty())
            .map(|(field, value)| (field.clone(), value.clone()))
            .collect();
        if settings.is_enabled()
            && !entered.is_empty()
            && let Err(error) = AICredentialStore::save(&entered, &settings.provider_id)
        {
            self.log_console(
                "AI credentials could not be saved",
                EditorConsoleSeverity::Error,
                Some(error.to_string()),
                None,
                None,
            );
            return false;
        }
        // Read the secret once here, on the user's Apply, so a key the session
        // cannot use fails now instead of leaving AI silently off.
        if settings.is_enabled() {
            let usable = provider
                .as_ref()
                .and_then(|provider| provider.secret_field())
                .and_then(|field| AICredentialStore::load(field, &settings.provider_id))
                .is_some();
            if !usable {
                let title = provider
                    .as_ref()
                    .map(|provider| provider.title.clone())
                    .unwrap_or_else(|| settings.provider_id.clone());
                self.log_console(
                    "AI settings were not applied",
                    EditorConsoleSeverity::Error,
                    Some(format!("Enter an API key for {title}.")),
                    None,
                    None,
                );
                return false;
            }
        }

        self.store.dispatch(EditorAction::SetAISettings(settings.clone()));
        self.store.dispatch(EditorAction::ClearChatHistory);

        let old_session = self.session.borrow_mut().clone();
        self.cancel_active_ai_request();
        self.agent_execution.borrow_mut().assistant_message_id = None;

        let agents = self.agent_catalog();
        let plugin_executor = self.plugin_capability_executor.borrow().clone();
        let query_provider = self.make_plugin_query_snapshot_provider();
        let tool_policy = Some(self.tool_access.policy.clone());
        let new_session = Self::make_session(
            settings,
            &providers,
            agents.agent(&settings.agent_id),
            &Default::default(),
            plugin_executor,
            query_provider,
            tool_policy,
        );

        if old_session.is_some() || new_session.is_some() {
            let world_view = self.ai_world_context.snapshot();
            let context = Self::workflow_context(
                self.store.content(),
                &self.scene.script_catalog_entries.borrow(),
            );
            let bus = Some(self.observation_bus.clone());
            let memory = self.context_memory_store.clone();
            let project_tools = self.make_project_tool_executor_arc();
            let component_descriptions = self.make_component_description_provider();
            if let Some(old_session) = &old_session {
                old_session.cancel_active_run();
            }
            if let Some(new_session) = &new_session {
                new_session.set_project_tool_executor(Some(project_tools));
                new_session.set_component_description_provider(Some(component_descriptions));
                new_session.replace_world_view(world_view);
                new_session.set_observation_bus(bus);
                new_session.set_context_memory(memory);
                new_session.set_workflow_context(Some(context));
            }
        }
        self.session.replace(new_session);
        self.plugin_session.state().ai_provider = provider;
        true
    }

    /// `applyCapabilitySettings(_:)` — stores the release phase and rebuilds the
    /// coordinator's planner so a narrowed gate takes effect immediately.
    pub fn apply_capability_settings(&self, settings: EditorCapabilitySettings) {
        self.store
            .dispatch(EditorAction::SetCapabilitySettings(settings.clone()));
        let executor = self.plugin_capability_executor.borrow().clone();
        self.intent_coordinator
            .configure_capability_planner(Self::make_capability_invocation_planner(
                &settings,
                executor.as_ref(),
            ));
    }

    /// `clearAIKey()` — removes the stored key for the current provider and
    /// disables the assistant.
    pub fn clear_ai_key(&self) -> bool {
        let provider_id = self.store.ai_settings().provider_id;
        if let Err(error) = AICredentialStore::delete(&provider_id) {
            self.log_console(
                "AI credentials could not be removed",
                EditorConsoleSeverity::Error,
                Some(error.to_string()),
                None,
                None,
            );
            return false;
        }
        let old_session = self.session.borrow_mut().clone();
        self.cancel_active_ai_request();
        if let Some(old_session) = &old_session {
            old_session.cancel_active_run();
        }
        self.session.replace(None);
        self.store.dispatch(EditorAction::ClearChatHistory);
        self.agent_execution.borrow_mut().assistant_message_id = None;
        let mut settings = self.store.ai_settings();
        settings.provider_id.clear();
        settings.model.clear();
        self.store.dispatch(EditorAction::SetAISettings(settings));
        true
    }

    /// `cancelActiveAIRequest()` — drops the confirmation, marks the task and
    /// message cancelled, and aborts the in-flight request.
    pub fn cancel_active_ai_request(&self) {
        if self.agent_execution.borrow().proposal.is_some()
            && self.store.pending_confirmation_request().is_some()
        {
            self.skip_pending_confirmation();
        }
        if self.agent_task_service.borrow().active_task().is_some() {
            self.update_agent_task(EditorAgentTaskPhase::Cancelled, "Task cancelled");
        }
        let assistant_message_id = self.agent_execution.borrow().assistant_message_id.clone();
        if let Some(id) = assistant_message_id {
            self.store.dispatch(EditorAction::UpdateChatMessage {
                id,
                assistant_state: AIChatAssistantState::Discarded,
            });
        }
        let mut execution = self.agent_execution.borrow_mut();
        execution.request_id = None;
        execution.request_task.take();
        execution.proposal = None;
    }

    /// `hasStoredAIKey(for:)` — true when the provider needs no secret or a
    /// credential is stored for its secret field.
    pub fn has_stored_ai_key(&self, provider_id: Option<&str>) -> bool {
        let id = provider_id
            .map(str::to_string)
            .unwrap_or_else(|| self.store.ai_settings().provider_id);
        let providers = self.ai_provider_catalog();
        let Some(provider) = providers.provider(&id) else {
            return false;
        };
        match provider.secret_field() {
            Some(field) => AICredentialStore::credential_source(field, &id).is_some(),
            None => true,
        }
    }

    /// `aiCredentialSource(for:field:)` — where an auth field's value comes from;
    /// the provider's secret field when `field_id` is nil.
    pub fn ai_credential_source(
        &self,
        provider_id: Option<&str>,
        field_id: Option<&str>,
    ) -> Option<AICredentialSource> {
        let id = provider_id
            .map(str::to_string)
            .unwrap_or_else(|| self.store.ai_settings().provider_id);
        let providers = self.ai_provider_catalog();
        let provider = providers.provider(&id)?;
        let field = match field_id {
            Some(field_id) => provider
                .auth_fields
                .iter()
                .find(|field| field.id == field_id),
            None => provider.secret_field(),
        }?;
        AICredentialStore::credential_source(field, &id)
    }

    /// `isSceneAuthoringEnabled` — authoring is permitted only when the
    /// simulation is stopped and the scene allows authoring.
    pub fn is_scene_authoring_enabled(&self) -> bool {
        self.store.playback_state() == PlaybackState::Stopped && self.scene.is_authoring_enabled()
    }

    /// `workflowContext(for:scriptEntries:)` — the content profile's context.
    pub fn workflow_context(
        content: EditorContent,
        script_entries: &[ProjectScriptCatalogEntry],
    ) -> WorkflowContext {
        let intent = GameplayIntent::new("game".to_string(), "not_specified".to_string());
        let mut constraints = GameKnownConstraints::new();
        constraints.scripting_registry = script_entries
            .iter()
            .map(|entry| entry.identifier.clone())
            .collect();
        constraints.script_schemas = script_entries.iter().map(Self::script_schema).collect();
        match content {
            EditorContent::Files => WorkflowContext::Workstation(WorkstationContext::new(
                WorkstationContextDomain::Documents,
            )),
            EditorContent::Timeline => WorkflowContext::Workstation(WorkstationContext::new(
                WorkstationContextDomain::Media,
            )),
            EditorContent::Scene => {
                let mut context =
                    GameWorkflowContext::new(intent, "Interactive level editing".to_string());
                context.known_constraints = constraints;
                WorkflowContext::Game(context)
            }
        }
    }

    /// `scriptSchema(_:)` — derives the parameter list from the preset's default
    /// JSON object, sorted by name.
    fn script_schema(entry: &ProjectScriptCatalogEntry) -> ScriptSchema {
        let parsed: Option<serde_json::Value> =
            serde_json::from_str(&entry.default_parameters_json).ok();
        let Some(serde_json::Value::Object(object)) = parsed else {
            return ScriptSchema::new(entry.identifier.clone());
        };
        let mut names: Vec<String> = object.keys().cloned().collect();
        names.sort();
        let parameters = names
            .into_iter()
            .map(|name| {
                diffuse_ai::context::workflow_context::ScriptParameterDescriptor::new(
                    name.clone(),
                    Self::script_parameter_type(object.get(&name)),
                )
            })
            .collect();
        ScriptSchema::new(entry.identifier.clone()).with_parameters(parameters)
    }

    /// `scriptParameterType(_:)` — the value kinds a preset can declare.
    fn script_parameter_type(value: Option<&serde_json::Value>) -> String {
        match value {
            Some(serde_json::Value::Bool(_)) => "Bool",
            Some(serde_json::Value::Number(_)) => "Number",
            Some(serde_json::Value::String(_)) => "String",
            Some(serde_json::Value::Array(items)) => {
                if items.len() == 3 {
                    "Vec3"
                } else {
                    "Array"
                }
            }
            Some(serde_json::Value::Object(_)) => "Object",
            _ => "Value",
        }
        .to_string()
    }

    /// `makeSession(for:providers:agent:initialWorldView:...)` — `None` when the
    /// settings, provider, format, base URL, key or model cannot be resolved.
    #[allow(clippy::too_many_arguments)]
    pub fn make_session(
        settings: &EditorAISettings,
        providers: &AIProviderCatalog,
        agent: Option<&crate::contributions::agents::AgentDescriptor>,
        initial_world_view: &diffuse_ai::context::world_view::WorldView,
        plugin_capability_executor: Option<
            diffuse_ai::tools::plugin_capability_executor::PluginCapabilityExecutor,
        >,
        plugin_query_snapshot_provider: Option<
            diffuse_ai::tools::plugin_capability_executor::PluginQuerySnapshotProvider,
        >,
        tool_policy: Option<ToolPolicy>,
    ) -> Option<std::sync::Arc<Session>> {
        if !settings.is_enabled() {
            return None;
        }
        let provider = providers.provider(&settings.provider_id)?;
        let api_format = Self::api_format(provider)?;
        let base_url = provider.base_url.clone()?;
        let key = provider
            .secret_field()
            .and_then(|field| AICredentialStore::load(field, &provider.id))?;
        // The user's choice wins, then the agent's preference, then the provider's default.
        let model = provider
            .models
            .iter()
            .find(|model| model.id == settings.model)
            .or_else(|| {
                agent
                    .and_then(|agent| agent.preferred_model.as_ref())
                    .and_then(|preferred| {
                        provider.models.iter().find(|model| &model.id == preferred)
                    })
            })
            .or_else(|| {
                provider
                    .models
                    .iter()
                    .find(|model| model.id == provider.default_model)
            })?;
        let model_limit = model.max_output_tokens.unwrap_or(8192);
        let max_tokens = agent
            .and_then(|agent| agent.max_output_tokens)
            .map(|tokens| tokens.min(model_limit))
            .unwrap_or(model_limit);
        let auto_approve = settings.auto_approve
            && agent.map(|agent| agent.can_auto_approve).unwrap_or(true);
        let config = SessionConfig::new(
            key,
            model.id.clone(),
            max_tokens,
            SessionConfig::DEFAULT_TIMEOUT_INTERVAL,
            base_url,
            api_format,
            auto_approve,
            Default::default(),
            Default::default(),
        );
        Some(std::sync::Arc::new(Session::new(
            None,
            config,
            None,
            None,
            Some(initial_world_view.clone()),
            None,
            plugin_capability_executor,
            plugin_query_snapshot_provider,
            tool_policy,
        )))
    }

    /// `apiFormat(for:)` — maps the provider's declared format string.
    fn api_format(provider: &AIProviderDescriptor) -> Option<SessionApiFormat> {
        match provider.api_format.as_str() {
            "anthropic" => Some(SessionApiFormat::Anthropic),
            "openai-responses" => Some(SessionApiFormat::OpenAiResponses),
            "openai-compatible" => Some(SessionApiFormat::OpenAiCompatible),
            _ => None,
        }
    }

    /// `makeCapabilityInvocationPlanner(for:pluginCapabilityExecutor:)` — the
    /// planner honours the configured release phase and the plugins' authorities.
    pub(crate) fn make_capability_invocation_planner(
        settings: &EditorCapabilitySettings,
        plugin_capability_executor: Option<
            &diffuse_ai::tools::plugin_capability_executor::PluginCapabilityExecutor,
        >,
    ) -> CapabilityInvocationPlanner {
        let gate = ReleasePhaseGate::new(settings.release_phase.runtime_phase());
        match plugin_capability_executor {
            Some(executor) => executor.make_invocation_planner(gate, false),
            None => CapabilityInvocationPlanner::new(
                BuiltInTypedCapabilityCatalog::registry(),
                gate,
                AmbiguityScorer::default(),
                false,
                BTreeMap::new(),
                std::sync::Arc::new(|_| true),
            ),
        }
    }

    /// The session-facing form of `makeProjectToolExecutor()`.
    fn make_project_tool_executor_arc(self: &Rc<Self>) -> ProjectToolExecutor {
        let app = SendableAppHandle(Rc::downgrade(self));
        std::sync::Arc::new(move |name: String, input: Vec<u8>| {
            let app = app.upgrade().ok_or_else(|| {
                Box::new(EditorProjectToolError::new("Editor is unavailable."))
                    as Box<dyn std::error::Error + Send + Sync>
            })?;
            app.execute_project_tool(&name, &input, ToolCallOrigin::AgentSession)
                .map_err(|error| Box::new(error) as Box<dyn std::error::Error + Send + Sync>)
        })
    }
}
