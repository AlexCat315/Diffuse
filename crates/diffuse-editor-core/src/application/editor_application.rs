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
use std::thread::JoinHandle;
use std::sync::mpsc::{self, Receiver};
use std::time::Instant;

use cove_graphics::rhi::Device;
use cove_logging::{Level, LogEvent, LogSystem, LogValue};
use cove_platform::InputEvent;
use cove_runtime::PlatformEventBridge;
use diffuse_ai::context::ai_world_context::AIWorldContext;
use diffuse_ai::context::world_view::WorldView;
use diffuse_ai::semantic::scene_semantic_encoder::SceneSemanticEncoder;
use diffuse_ai::session::session::Session;
use diffuse_ai::tools::plugin_capability_executor::PluginCapabilityExecutor;
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
use crate::ai::chat::editor_agent_task_service::{EditorAgentExecution, EditorAgentTaskService};
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

/// Swift declares `EditorApplication: @unchecked Sendable`. The assistant host
/// seams (`PluginQuerySnapshotProvider`, the component-description provider)
/// hand a weak reference to worker threads; those closures only reach the
/// editor-thread entry points the session schedules.
pub(crate) struct SendableAppHandle(pub std::rc::Weak<EditorApplication>);

impl SendableAppHandle {
    /// Upgrades the weak link; callers run on the editor thread.
    pub(crate) fn upgrade(&self) -> Option<std::rc::Rc<EditorApplication>> {
        self.0.upgrade()
    }
}

// SAFETY: the handle only carries a `Weak<EditorApplication>`; every call site
// goes through the same editor-thread entry points `EditorApplication` already
// exposes to other threads. Callers must not observe the Rc's refcount on two
// threads at once, which the single owner guarantees.
unsafe impl Send for SendableAppHandle {}
// SAFETY: same contract as above.
unsafe impl Sync for SendableAppHandle {}

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
    pub(crate) agent_task_service: RefCell<EditorAgentTaskService>,
    /// Agent session backing the AI assistant (Swift `session`).
    pub(crate) session: RefCell<Option<Arc<Session>>>,
    /// Tracks the in-flight agent request and its pending proposal.
    pub(crate) agent_execution: RefCell<EditorAgentExecution>,
    /// Background task that swaps in a new Session without blocking the main thread.
    pub(crate) pending_ai_setup_task: RefCell<Option<JoinHandle<()>>>,
    /// Background task streaming world observations into the active Session.
    pub(crate) pending_world_observation_task: RefCell<Option<JoinHandle<()>>>,
    /// Bridges plugin-declared capabilities into the agent runtime.
    pub(crate) plugin_capability_executor: RefCell<Option<PluginCapabilityExecutor>>,
    /// Guards project-tool execution while a build is in flight.
    pub(crate) project_tool_build_in_progress: RefCell<bool>,
    pub edit_log: EditLog,
    pub context_memory_store: Option<std::sync::Arc<ContextMemoryStore>>,
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
    last_prepared_scene_revision: std::cell::Cell<Option<u64>>,
    script_catalog_elapsed: std::cell::Cell<f64>,
    frame_clock: Instant,
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

    /// Starts the engine and attaches the platform event stream for this window.
    pub fn bootstrap(self: &Rc<Self>) -> cove_graphics::rhi::RhiResult<()> {
        if self.engine.is_started() {
            return Ok(());
        }
        self.queue_viewport_render_settings();
        let renderer = self.engine.prepare_renderer(None, true, &self.last_queued_render_settings.borrow(), |_| ())?;
        let manager = self.workstation.scripts.manager().clone();
        self.workstation.tasks.set_test_source(Some(Arc::new(move || {
            manager.workspace_tests().map_err(|error| error.to_string())
        })));
        self.workstation.tasks.follow(&self.workstation.scripts);
        self.last_prepared_scene_revision.set(None);
        self.render_gate.replace(EditorViewportRenderGate::new());
        self.engine.start(None, false, renderer.map(|renderer| Box::new(renderer) as Box<_>));
        self.engine.set_render_completion_handler(Some(Arc::new(|_| cove_runtime::scene::wake_scene_thread())));
        let app = Rc::downgrade(self);
        self.subscriptions.set_events(Some(self.events.subscribe(move |event| {
            if let Some(app) = app.upgrade() {
                app.handle_platform_event(event);
            }
        })));
        self.store.dispatch(EditorAction::SetConnected(true));
        self.request_display_refresh();
        Ok(())
    }

    /// Advances one editor frame and publishes the completed engine surface.
    pub fn tick(self: &Rc<Self>, elapsed: f64) {
        use crate::editing::viewport::editor_viewport_frame_drive::EditorViewportFrameDrive;
        use crate::editing::viewport::editor_viewport_render_gate::EditorViewportRenderGateSignature;
        use crate::state::editor_state::PlaybackState;
        use crate::state::workspace::editor_workbench_state::EditorViewportMode;

        if !self.is_active() {
            return;
        }
        for record in self.subscriptions.console.take() {
            self.store.dispatch(EditorAction::AppendLogRecord(record));
        }
        self.poll_project_export();
        self.poll_script_reload();
        let elapsed = elapsed.max(0.0);
        let catalog_elapsed = self.script_catalog_elapsed.get() + elapsed;
        if catalog_elapsed >= 1.0 {
            self.script_catalog_elapsed.set(0.0);
            self.reload_project_scripts(false, true);
        } else {
            self.script_catalog_elapsed.set(catalog_elapsed);
        }
        self.autosave_scene_if_needed(elapsed, false);

        let surface = self.engine.current_viewport_surface_state();
        if *self.last_viewport_surface_state.borrow() != surface {
            self.last_viewport_surface_state.replace(surface);
            self.store.dispatch(EditorAction::ViewportSurfaceUpdated);
        }
        if !self.engine.is_started() {
            return;
        }

        let next_frame = self.store.frame_index().wrapping_add(1);
        self.store.dispatch(EditorAction::TickFrame(next_frame));
        let events = self.pending_viewport_events.take();
        self.input_state.borrow_mut().process(&events);
        let playing = self.store.playback_state() == PlaybackState::Playing;
        let realtime = self.store.viewport_realtime_enabled();
        let advance = playing || (realtime && self.store.playback_state() == PlaybackState::Stopped);
        let simulation_delta = if advance { elapsed.min(0.25) } else { 0.0 };
        self.drive_continuous_viewport_camera(elapsed.min(0.25));
        let revision = self.scene.revision();
        if advance || self.last_prepared_scene_revision.get() != Some(revision) {
            self.scene.tick_scene(simulation_delta, next_frame, events.clone(), playing);
            self.last_prepared_scene_revision.set(Some(self.scene.revision()));
        }
        let presenting = self.store.should_render();
        let continuous = EditorViewportFrameDrive::wants_continuous_frames(realtime, self.store.playback_state(), self.viewport_interacting(), presenting);
        let size = self.effective_viewport_drawable_size();
        let joint_palettes = self.scene.current_joint_palette_map();
        let overlays = self.make_geometry_overlays(size);
        let render = self.render_gate.borrow_mut().should_render(
            EditorViewportRenderGateSignature::with_overlays(self.scene.revision(), self.scene.current_render_camera(), size, *self.render_settings_generation.borrow(), joint_palettes.clone(), overlays.clone()),
            continuous, !events.is_empty(), self.last_queued_render_settings.borrow().post_processing.taa,
            presenting, self.frame_clock.elapsed().as_secs_f64(),
        );
        if advance || render {
            let mut render_scene = self.scene.current_render_scene();
            render_scene.geometry_overlays = overlays;
            let game = self.store.viewport_mode() == EditorViewportMode::Game;
            self.engine.tick(simulation_delta, events, size, render, Some(render_scene),
                Some(self.scene.current_scene_snapshot()), Some(joint_palettes),
                Some(if game && self.store.game_preview_hud_enabled() { self.scene.current_in_game_canvas() } else { Default::default() }),
                Some(self.scene.make_particle_simulation_feedback_handler()),
                game && self.store.game_preview_resolution().size().is_some(),
            );
        }
        if continuous {
            self.request_display_refresh();
        }
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
            agent_task_service: RefCell::new(EditorAgentTaskService::new()),
            session: RefCell::new(None),
            agent_execution: RefCell::new(EditorAgentExecution::new()),
            pending_ai_setup_task: RefCell::new(None),
            pending_world_observation_task: RefCell::new(None),
            plugin_capability_executor: RefCell::new(None),
            project_tool_build_in_progress: RefCell::new(false),
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
            last_prepared_scene_revision: std::cell::Cell::new(None),
            script_catalog_elapsed: std::cell::Cell::new(0.0),
            frame_clock: Instant::now(),
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
        if handler.is_none() {
            self.subscriptions.console.set_wake(None);
        }
        self.display_invalidation_handler.replace(handler);
    }

    /// `logConsole(_:severity:detail:target:nextStep:)` — writes one console
    /// entry; the project directory rides along as log context metadata.
    pub fn log_console(
        &self,
        message: &str,
        severity: EditorConsoleSeverity,
        detail: Option<String>,
        target: Option<EditorIssueTarget>,
        next_step: Option<String>,
    ) {
        self.store.dispatch(EditorAction::AppendConsoleMessage {
            message: message.into(),
            severity,
            detail,
            target,
            next_step,
        });
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
