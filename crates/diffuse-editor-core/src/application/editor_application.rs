//! `Editor/Sources/EditorCore/Application/EditorApplication.swift`.
//!
//! The editor application domain: the engine host, the editor store and input
//! state for one window. Construction and the per-domain behaviour live here and
//! in the `application/**` extension modules; this file owns the shared fields.

use std::cell::{OnceCell, RefCell};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver};

use cove_graphics::rhi::Device;
use cove_logging::{Level, LogEvent, LogSystem, LogValue};
use cove_platform::InputEvent;
use cove_runtime::PlatformEventBridge;
use diffuse_ai::context::ai_world_context::AIWorldContext;
use diffuse_ai::context::world_view::WorldView;
use diffuse_ai::semantic::scene_semantic_encoder::SceneSemanticEncoder;
use diffuse_ai::tools::tool_policy::ToolPolicy;
use diffuse_assets::asset_registry::AssetRegistryError;
use diffuse_capability::release::release_phase_gate::ReleasePhaseGate;
use diffuse_context_memory::context_memory_store::ContextMemoryStore;
use diffuse_engine::engine_core::EngineHost;
use diffuse_engine::engine_ffi::BridgedEngineRuntime;
use diffuse_intent::BuiltInTypedCapabilityCatalog;
use diffuse_intent::intent_runtime_coordinator::IntentRuntimeCoordinator;
use diffuse_intent::invocation::ambiguity_scorer::AmbiguityScorer;
use diffuse_intent::invocation::capability_invocation_planning::CapabilityInvocationPlanner;
use diffuse_intent::transactions::intent_transaction_builder::IntentTransactionBuilder;
use diffuse_intent::transactions::transaction_executor::TransactionExecutor;
use diffuse_intent::transactions::undo_stack::UndoStack;
use diffuse_observation::cold_log::ObservationBusError;
use diffuse_observation::event_kind_registry::EventKindRegistry;
use diffuse_observation::publisher::ObservationBus;
use diffuse_perception::core::perception_service::PerceptionService;
use diffuse_plugin::lifecycle::status::PluginManagerError;
use diffuse_render::core::render_stats::RenderFrameStats;
use diffuse_render::surface::in_game_ui_providing::InGameUIProviding;
use diffuse_render::surface::viewport_surface::ViewportSurfaceState;
use diffuse_render::{RenderDrawableSize, RenderSettings};

use crate::ai::chat::edit_log::EditLog;
use crate::ai::chat::editor_agent_task_service::EditorAgentTaskService;
use crate::ai::chat::editor_ai_settings::{EditorAISettings, EditorCapabilitySettings};
use crate::ai::plugins::editor_plugin_host_locator::EditorPluginHostLocator;
use crate::ai::tools::access::EditorToolAccess;
use crate::ai::tools::audit::EditorToolAudit;
use crate::application::diagnostics::subscriptions::EditorSubscriptions;
use crate::application::persistence::scene_persistence::EditorScenePersistence;
use crate::application::plugins::plugin_session::{PluginSession, PluginSessionError};
use crate::application::projects::export::ProjectExportJob;
use crate::application::scripting::scripting::{SceneScriptReloadEvent, ScriptWorkspaceEvent};
use crate::assets::asset_catalog::EditorAssetCatalog;
use crate::assets::project_runtime_resources::ProjectRuntimeResources;
use crate::diagnostics::session::EditorDiagnosticSession;
use crate::editing::viewport::editor_viewport_render_gate::EditorViewportRenderGate;
use crate::geometry::editor_geometry_authoring::EditorGeometryAuthoring;
use crate::geometry::editor_mesh_editing::EditorMeshEditing;
use crate::input::input_state::InputState;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;
use crate::scripting::assets::script_workspace_model::ScriptWorkspaceModel;
use crate::scripting::dynamic::dynamic_script_manager::{
    DynamicScriptManager, DynamicScriptManagerError,
};
use crate::scripting::dynamic::project_script_catalog::ProjectScriptCatalogMonitor;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::EditorConsoleSeverity;
use crate::state::editor_store::EditorStore;
use crate::state::workspace::editor_workbench_state::EditorIssueTarget;
use crate::workstation::services::EditorWorkstation;

/// The panel activation hook installed by the app shell.
pub type ActivatePanelHandler = std::rc::Rc<dyn Fn(&str)>;

#[derive(Default)]
pub struct EditorApplicationOptions {
    pub seed_preview_scene: bool,
    pub render_device: Option<Arc<Device>>,
    pub in_game_ui: Option<Box<dyn InGameUIProviding>>,
    pub events: PlatformEventBridge,
    pub initial_ai_settings: EditorAISettings,
    pub initial_capability_settings: EditorCapabilitySettings,
    pub trusted_plugin_host_executable: Option<PathBuf>,
    pub tool_policy: Option<ToolPolicy>,
    /// Source directories for the script crates used by language analysis.
    pub script_crate_paths: Vec<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum EditorApplicationError {
    #[error(transparent)]
    Assets(#[from] AssetRegistryError),
    #[error(transparent)]
    Plugins(#[from] PluginSessionError),
    #[error(transparent)]
    Observation(#[from] ObservationBusError),
    #[error(transparent)]
    Scripts(#[from] DynamicScriptManagerError),
    #[error(transparent)]
    Workstation(#[from] diffuse_media::MediaError),
}

pub struct EditorApplication {
    pub engine: EngineHost,
    pub project_directory: String,
    pub store: Rc<EditorStore>,
    pub input_state: RefCell<InputState>,
    pub scene: EditorSceneAdapter,
    /// Canonical editor-facing state for script documents, diagnostics, builds,
    /// media, version control and tasks.
    pub workstation: Arc<EditorWorkstation>,
    /// Plugin session state: bindings, authorizations and declared components.
    pub plugin_session: PluginSession,
    pub observation_bus: Arc<ObservationBus>,
    pub intent_coordinator: IntentRuntimeCoordinator,
    pub(crate) tool_access: EditorToolAccess,
    pub intent_transaction_builder: IntentTransactionBuilder,
    pub ai_world_context: AIWorldContext,
    pub perception_service: PerceptionService,
    pub events: PlatformEventBridge,
    pub subscriptions: EditorSubscriptions,
    pub render_gate: RefCell<EditorViewportRenderGate>,
    pub agent_task_service: EditorAgentTaskService,
    pub edit_log: EditLog,
    pub context_memory_store: Option<ContextMemoryStore>,
    pub project_script_catalog_monitor: ProjectScriptCatalogMonitor,
    pub diagnostic_session: EditorDiagnosticSession,
    pub trusted_plugin_host_executable_url: Option<PathBuf>,
    /// Buffered viewport input until the engine's next tick.
    pub pending_viewport_events: RefCell<Vec<InputEvent>>,
    pub viewport_drawable_size: RefCell<diffuse_render::RenderDrawableSize>,
    pub last_viewport_surface_state: RefCell<ViewportSurfaceState>,
    pub render_settings_generation: RefCell<u64>,
    pub last_queued_render_settings: RefCell<RenderSettings>,
    pub last_render_frame_stats: RefCell<RenderFrameStats>,
    pub is_shutting_down: std::sync::atomic::AtomicBool,
    pub activate_panel_handler: RefCell<Option<ActivatePanelHandler>>,
    pub(crate) close_project_handler: RefCell<Option<Rc<dyn Fn()>>>,
    pub(crate) display_invalidation_handler: RefCell<Option<Rc<dyn Fn()>>>,
    pub(crate) geometry_authoring: OnceCell<Rc<EditorGeometryAuthoring>>,
    pub(crate) mesh_editing: OnceCell<Rc<EditorMeshEditing>>,
    pub(crate) scene_persistence: OnceCell<EditorScenePersistence>,
    pub(crate) script_reload_events: RefCell<Vec<Receiver<SceneScriptReloadEvent>>>,
    pub(crate) script_workspace_events: Receiver<ScriptWorkspaceEvent>,
    pub(crate) project_export: RefCell<Option<ProjectExportJob>>,
}

// SAFETY: Swift declares `EditorApplication: @unchecked Sendable`; the editor
// owns its scene tree, store and view pipeline on one thread. The render thread
// only reaches the engine host and the HUD snapshot channel, both of which are
// internally synchronized.
unsafe impl Send for EditorApplication {}
// SAFETY: same contract as above: cross-thread callers must confine themselves
// to the internal locks (`EngineHost`, `ObserverBus`, subscription channels).
unsafe impl Sync for EditorApplication {}

impl EditorApplication {
    pub fn new(project_directory: String) -> Result<Rc<Self>, EditorApplicationError> {
        Self::with_options(project_directory, EditorApplicationOptions::default())
    }

    pub fn with_options(
        project_directory: String,
        options: EditorApplicationOptions,
    ) -> Result<Rc<Self>, EditorApplicationError> {
        EditorAssetCatalog::load_project_default(&project_directory)?;
        let root = Path::new(&project_directory);
        let injected_host = options.trusted_plugin_host_executable.clone();
        let plugin_session = PluginSession::new(
            &project_directory,
            move || {
                EditorPluginHostLocator::resolve(injected_host.as_deref())
                    .ok_or_else(|| PluginManagerError::RuntimeUnavailable.into())
            },
            |plugin_id| {
                LogSystem::logger("com.cove.editor.plugins").log(
                    &LogEvent::new(Level::Error, "Plugin host exited unexpectedly").with_metadata(
                        BTreeMap::from([("plugin".into(), LogValue::String(plugin_id.into()))]),
                    ),
                );
            },
        )?;
        let scene = EditorSceneAdapter::new(
            options.seed_preview_scene,
            plugin_session.components.registry(),
            EditorInspectorRendererRegistry::built_in(),
        );
        scene.set_editor_viewport_camera_enabled(true);
        scene.script_runtime.set_gameplay_execution_enabled(false);
        ProjectRuntimeResources::configure_audio_search_paths(
            &scene.audio_engine,
            &project_directory,
        );

        let store = Rc::new(EditorStore::new());
        let selected = scene.default_selection_id();
        let snapshot = SceneSemanticEncoder::new().encode(
            &scene.scene(),
            selected,
            Some(store.content().raw_value().into()),
            None,
        );
        let mut world_view = WorldView::default();
        world_view.apply_snapshot(&snapshot);
        let ai_world_context = AIWorldContext::new(world_view);
        let observation_bus = Arc::new(ObservationBus::new(
            EventKindRegistry::default_registry(),
            Some(
                root.join(".cove/observation")
                    .to_string_lossy()
                    .into_owned(),
            ),
            256,
        )?);
        observation_bus.register_snapshot_provider(Box::new(ai_world_context.clone()), "scene");
        let planner = CapabilityInvocationPlanner::new(
            BuiltInTypedCapabilityCatalog::registry(),
            ReleasePhaseGate::new(
                options
                    .initial_capability_settings
                    .release_phase
                    .runtime_phase(),
            ),
            AmbiguityScorer::default(),
            false,
            BTreeMap::new(),
            Arc::new(|_| true),
        );
        let intent_coordinator = IntentRuntimeCoordinator::new(
            TransactionExecutor::new(),
            planner,
            UndoStack::default(),
        );
        {
            let mut plugin_state = plugin_session.state();
            plugin_state.ai_provider = plugin_state
                .providers
                .provider(&options.initial_ai_settings.provider_id)
                .cloned();
        }
        store.dispatch(EditorAction::SetAISettings(options.initial_ai_settings));
        store.dispatch(EditorAction::SetCapabilitySettings(
            options.initial_capability_settings,
        ));
        store.dispatch(EditorAction::SetSceneRevision(scene.revision()));
        store.dispatch(EditorAction::MarkSceneSaved(scene.revision()));
        store.dispatch(EditorAction::SetSelectedEntity(selected));

        let script_crate_paths = if options.script_crate_paths.is_empty() {
            let source = Path::new(env!("CARGO_MANIFEST_DIR")).with_file_name("diffuse-script-api");
            if source.join("Cargo.toml").is_file() {
                vec![source.to_string_lossy().into_owned()]
            } else {
                Vec::new()
            }
        } else {
            options.script_crate_paths
        };
        let manager = Arc::new(DynamicScriptManager::new(
            &project_directory,
            scene.script_runtime.clone(),
            script_crate_paths,
        ));
        let (script_sender, script_workspace_events) = mpsc::channel();
        let script_loaded = script_sender.clone();
        let script_deleted = script_sender.clone();
        let scripts = ScriptWorkspaceModel::with_handlers(
            manager,
            Some(Arc::new(move |file| {
                let _ = script_loaded.send(ScriptWorkspaceEvent::Loaded(Box::new(file.clone())));
            })),
            Some(Arc::new(move |file| {
                let _ = script_deleted.send(ScriptWorkspaceEvent::Deleted(file.identifier.clone()));
            })),
            Some(Arc::new(move |file, message| {
                let _ = script_sender.send(ScriptWorkspaceEvent::BuildFailed(
                    Box::new(file.clone()),
                    message.into(),
                ));
            })),
        )?;
        let workstation = EditorWorkstation::new(root, scripts, plugin_session.runtime.clone())?;
        let (context_memory_store, context_memory_warning) =
            Self::initialize_context_memory(&root.join(".cove/context_memory.json"));
        let perception_service = PerceptionService::new();
        #[cfg(target_vendor = "apple")]
        perception_service.register(Arc::new(
            diffuse_perception::worker::apple_vision_perception_worker::AppleVisionPerceptionWorker::new(),
        ));

        let app = Rc::new(Self {
            engine: EngineHost::new(
                Arc::new(BridgedEngineRuntime::new()),
                options.render_device,
                options.in_game_ui,
            ),
            edit_log: EditLog::new(root),
            project_script_catalog_monitor: ProjectScriptCatalogMonitor::new(
                project_directory.clone(),
            ),
            project_directory,
            store,
            input_state: RefCell::new(InputState::new()),
            scene,
            workstation,
            plugin_session,
            observation_bus,
            intent_coordinator,
            tool_access: EditorToolAccess::new(
                options.tool_policy.unwrap_or_else(EditorToolAudit::policy),
            ),
            intent_transaction_builder: IntentTransactionBuilder::new(),
            ai_world_context,
            perception_service,
            events: options.events,
            subscriptions: EditorSubscriptions::new(),
            render_gate: RefCell::new(EditorViewportRenderGate::new()),
            agent_task_service: EditorAgentTaskService::new(),
            context_memory_store,
            diagnostic_session: EditorDiagnosticSession::new(),
            trusted_plugin_host_executable_url: EditorPluginHostLocator::resolve(
                options.trusted_plugin_host_executable.as_deref(),
            ),
            pending_viewport_events: RefCell::default(),
            viewport_drawable_size: RefCell::new(RenderDrawableSize::new(1280, 720)),
            last_viewport_surface_state: RefCell::default(),
            render_settings_generation: RefCell::default(),
            last_queued_render_settings: RefCell::default(),
            last_render_frame_stats: RefCell::default(),
            is_shutting_down: AtomicBool::new(false),
            activate_panel_handler: RefCell::default(),
            close_project_handler: RefCell::default(),
            display_invalidation_handler: RefCell::default(),
            geometry_authoring: OnceCell::new(),
            mesh_editing: OnceCell::new(),
            scene_persistence: OnceCell::new(),
            script_reload_events: RefCell::default(),
            script_workspace_events,
            project_export: RefCell::default(),
        });
        if let Some(detail) = context_memory_warning {
            app.log_warning("Recovered AI context memory storage", detail);
        }
        if let Some(detail) = &app.plugin_session.authorization_store.load_warning {
            app.log_warning("Recovered plugin authorization storage", detail.clone());
        }
        app.connect_scene_callbacks();
        app.reload_scripts_after_scene_replacement();
        Ok(app)
    }

    fn connect_scene_callbacks(self: &Rc<Self>) {
        let app = Rc::downgrade(self);
        self.scene
            .on_viewport_camera_changed
            .replace(Some(Rc::new(move || {
                if let Some(app) = app.upgrade() {
                    app.store.dispatch(EditorAction::ViewportCameraChanged);
                    app.request_display_refresh();
                }
            })));
        let store = Rc::downgrade(&self.store);
        self.scene
            .on_revision_changed
            .replace(Some(Rc::new(move |revision| {
                if let Some(store) = store.upgrade() {
                    store.dispatch(EditorAction::SetSceneRevision(revision));
                }
            })));
        let store = Rc::downgrade(&self.store);
        self.scene
            .on_transaction_error
            .replace(Some(Rc::new(move |message| {
                if let Some(store) = store.upgrade() {
                    store.dispatch(EditorAction::AppendConsoleMessage {
                        message: "Scene edit failed".into(),
                        severity: EditorConsoleSeverity::Error,
                        detail: Some(message),
                        target: store
                            .selected_entity_id()
                            .map(|id| EditorIssueTarget::Entity { id }),
                        next_step: Some(
                            "Stop playback, check the entity lock and property value, then retry."
                                .into(),
                        ),
                    });
                }
            })));
        // Both editors register their inspector providers as they are created.
        self.mesh_editing();
    }

    fn log_warning(&self, message: &str, detail: String) {
        self.store.dispatch(EditorAction::AppendConsoleMessage {
            message: message.into(),
            severity: EditorConsoleSeverity::Warning,
            detail: Some(detail),
            target: None,
            next_step: None,
        });
    }

    pub fn shutdown(&self) {
        if self.is_shutting_down.swap(true, Ordering::AcqRel) {
            return;
        }
        self.subscriptions.console.stop();
        self.project_export.take();
        self.leave_geometry_editing();
        self.subscriptions.renderer_preparation.cancel();
        self.diagnostic_session.close();
        let scripts = &self.scene.script_runtime;
        scripts.set_gameplay_execution_enabled(false);
        self.scene.with_scene_mut(|scene| scripts.stop(scene));
        self.workstation.scripts.shutdown();
        self.workstation.version_control.stop_monitoring();
        self.scene.end_interactive_edit_history_group();
        self.scene_persistence().finish_session();
        self.flush_context_memory_before_shutdown();
        self.store
            .dispatch(EditorAction::console_message("Editor runtime shutdown"));
        self.plugin_session.stop();
        if let Some(token) = self.subscriptions.events() {
            self.events.unsubscribe(token);
        }
        self.subscriptions.stop(&self.store);
        self.engine.shutdown();
    }

    pub(crate) fn leave_geometry_editing(&self) {
        if let Some(mesh) = self.mesh_editing.get()
            && mesh.is_editing()
        {
            mesh.leave();
        }
        if let Some(authoring) = self.geometry_authoring.get() {
            authoring.cancel_interactive_edit();
        }
    }

    pub(crate) fn refresh_scene_world_view(&self) {
        let snapshot = SceneSemanticEncoder::new().encode(
            &self.scene.scene(),
            self.store.selected_entity_id(),
            Some(self.store.content().raw_value().into()),
            None,
        );
        let mut world_view = WorldView::default();
        world_view.apply_snapshot(&snapshot);
        self.ai_world_context.replace_world_view(world_view);
    }

    pub fn mesh_editing(self: &Rc<Self>) -> &Rc<EditorMeshEditing> {
        self.mesh_editing.get_or_init(|| {
            let app = Rc::downgrade(self);
            EditorMeshEditing::new(
                Rc::clone(self.geometry_authoring()),
                self.scene.clone(),
                Rc::clone(&self.store),
                Rc::new(move || {
                    if let Some(app) = app.upgrade() {
                        app.request_display_refresh();
                    }
                }),
            )
        })
    }

    pub fn geometry_authoring(self: &Rc<Self>) -> &Rc<EditorGeometryAuthoring> {
        self.geometry_authoring.get_or_init(|| {
            let app = Rc::downgrade(self);
            EditorGeometryAuthoring::new(
                self.project_directory.clone().into(),
                self.scene.clone(),
                Rc::clone(&self.store),
                self.workstation.documents.clone(),
                Rc::new(move || {
                    if let Some(app) = app.upgrade() {
                        app.render_gate.replace(EditorViewportRenderGate::new());
                        app.request_display_refresh();
                    }
                }),
            )
        })
    }

    pub fn set_display_invalidation_handler(&self, handler: Option<Rc<dyn Fn()>>) {
        self.display_invalidation_handler.replace(handler);
    }

    pub fn request_display_refresh(&self) {
        let handler = self.display_invalidation_handler.borrow().clone();
        if let Some(handler) = handler {
            handler();
        }
    }

    pub fn is_active(&self) -> bool {
        !self
            .is_shutting_down
            .load(std::sync::atomic::Ordering::Acquire)
    }

    pub fn set_activate_panel_handler(&self, handler: impl Fn(&str) + 'static) {
        *self.activate_panel_handler.borrow_mut() = Some(std::rc::Rc::new(handler));
    }

    /// Tool policy enforced for the assistant, the MCP bridge and project tools.
    pub(crate) fn tool_access(&self) -> &EditorToolAccess {
        &self.tool_access
    }

    pub fn show_panel(&self, id: &str) {
        if let Some(handler) = self.activate_panel_handler.borrow().as_ref() {
            handler(id);
        }
    }
}
