//! `Editor/Sources/EditorCore/Application/EditorApplication.swift`.
//!
//! The editor application domain: the engine host, the editor store and input
//! state for one window. Construction and the per-domain behaviour live here and
//! in the `application/**` extension modules; this file owns the shared fields.

use std::cell::RefCell;
use std::path::PathBuf;

use cove_platform::InputEvent;
use cove_runtime::PlatformEventBridge;
use diffuse_ai::context::ai_world_context::AIWorldContext;
use diffuse_context_memory::context_memory_store::ContextMemoryStore;
use diffuse_engine::engine_core::EngineHost;
use diffuse_intent::intent_runtime_coordinator::IntentRuntimeCoordinator;
use diffuse_intent::transactions::intent_transaction_builder::IntentTransactionBuilder;
use diffuse_observation::publisher::ObservationBus;
use diffuse_perception::core::perception_service::PerceptionService;
use diffuse_render::RenderSettings;
use diffuse_render::core::render_stats::RenderFrameStats;
use diffuse_render::surface::viewport_surface::ViewportSurfaceState;

use crate::ai::chat::edit_log::EditLog;
use crate::ai::chat::editor_agent_task_service::EditorAgentTaskService;
use crate::ai::tools::access::EditorToolAccess;
use crate::application::diagnostics::subscriptions::EditorSubscriptions;
use crate::application::plugins::plugin_session::PluginSession;
use crate::editing::viewport::editor_viewport_render_gate::EditorViewportRenderGate;
use crate::input::input_state::InputState;
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scripting::dynamic::project_script_catalog::ProjectScriptCatalogMonitor;
use crate::state::editor_store::EditorStore;

/// The panel activation hook installed by the app shell.
pub type ActivatePanelHandler = std::rc::Rc<dyn Fn(&str)>;

pub struct EditorApplication {
    pub engine: EngineHost,
    pub project_directory: String,
    pub store: EditorStore,
    pub input_state: RefCell<InputState>,
    pub scene: EditorSceneAdapter,
    /// Plugin session state: bindings, authorizations and declared components.
    pub plugin_session: PluginSession,
    pub observation_bus: ObservationBus,
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
