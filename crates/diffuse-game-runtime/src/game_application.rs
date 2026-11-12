//! Translation of `Editor/Sources/GameRuntime/GameApplication.swift`.
//!
//! Lightweight game host for the standalone player. The project directory is
//! optional: without one the host keeps the seeded preview scene and the
//! built-in script catalog. With one, the asset index, the exported/preview
//! scene and the compiled scripts load before the engine starts, and
//! `Scripts/scripts.json` keeps being watched so authoring changes reach a
//! running game.
//!
//! Swift wrapped the host in `@MainActor` and drove it from `Application.run`;
//! that entry point stays with the player's UI layer. The Rust host is owned by
//! one thread and exposes synchronous methods, using `Cell`/`RefCell`/`Mutex`
//! for the state Swift mutated through a shared reference. The pending input
//! queue sits behind a mutex so `&self` callbacks can enqueue without a
//! mutable borrow of the host; the `EditorSceneAdapter` it owns is `Rc`-based,
//! so the whole host stays on that one thread.
//!
//! `bootstrapPrepared(onProgress:)` was async and checked `Task` cancellation.
//! Rust has no async runtime: [`GameApplication::bootstrap_prepared`] takes the
//! same progress callback synchronously, and
//! [`GameApplication::bootstrap_prepared_while`] adds an explicit cancellation
//! probe in place of the ambient `Task.checkCancellation()`.

use std::cell::{Cell, RefCell};
use std::fmt;
use std::path::Path;
use std::rc::Rc;
use std::sync::{Arc, Mutex};

use cove_graphics::rhi::{Device, ResourcePreparationProgress, RhiError};
use cove_logging::{Level, LogEvent, LogSystem};
use diffuse_assets::asset_registry::AssetRegistryError;
use diffuse_editor_core::assets::asset_catalog::EditorAssetCatalog;
use diffuse_editor_core::assets::project_runtime_resources::ProjectRuntimeResources;
use diffuse_editor_core::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use diffuse_editor_core::scene::adapter::scripts::EditorScriptCatalogApplyReport;
use diffuse_editor_core::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;
use diffuse_editor_core::scene::manifest::editor_scene_manifest::EditorSceneManifestLoadError;
use diffuse_editor_core::scripting::dynamic::project_script_catalog::{
    ProjectScriptCatalog, ProjectScriptCatalogDiagnostic, ProjectScriptCatalogMonitor,
};
use diffuse_engine::engine_core::EngineHost;
use diffuse_engine::engine_ffi::BridgedEngineRuntime;
use diffuse_kernel::input_event::InputEvent;
use diffuse_render::surface::in_game_ui_providing::InGameUIProviding;
use diffuse_render::surface::viewport_surface::ViewportSurfaceState;
use diffuse_render::{RenderDrawableSize, RenderPacketConsumer, RenderSettings};
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_script::ScriptRuntime;

use crate::game_project_asset_index_loader::{
    GameProjectAssetIndexError, GameProjectAssetIndexLoader,
};
use crate::game_project_scene_loader::{GameProjectSceneLoadError, GameProjectSceneLoader};
use crate::game_project_script_loader::{GameProjectScriptLoadError, GameProjectScriptLoader};

const SCRIPT_LOG_TARGET: &str = "com.cove.player.scripting";

/// Swift's `registerProjectScripts: ((ScriptRuntime) -> Int)?`.
pub type ProjectScriptRegistrar = Box<dyn Fn(&ScriptRuntime) -> i64>;

/// Swift's `onViewportSurfaceChanged: ((ViewportSurfaceState) -> Void)?`.
pub type ViewportSurfaceChangedHandler = Rc<dyn Fn(ViewportSurfaceState)>;

/// Failures of [`GameApplication::new`] and renderer preparation.
#[derive(Debug)]
pub enum GameApplicationError {
    AssetIndex(GameProjectAssetIndexError),
    AssetCatalog(AssetRegistryError),
    SceneLoader(GameProjectSceneLoadError),
    SceneManifest(EditorSceneManifestLoadError),
    Scripts(GameProjectScriptLoadError),
    Renderer(RhiError),
    /// Swift's `CancellationError` from `Task.checkCancellation()`.
    Cancelled,
}

impl fmt::Display for GameApplicationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::AssetIndex(error) => error.fmt(formatter),
            Self::AssetCatalog(error) => error.fmt(formatter),
            Self::SceneLoader(error) => error.fmt(formatter),
            Self::SceneManifest(error) => error.fmt(formatter),
            Self::Scripts(error) => error.fmt(formatter),
            Self::Renderer(error) => error.fmt(formatter),
            Self::Cancelled => formatter.write_str("cancelled"),
        }
    }
}

impl std::error::Error for GameApplicationError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::AssetIndex(error) => Some(error),
            Self::AssetCatalog(error) => Some(error),
            Self::SceneLoader(error) => Some(error),
            Self::SceneManifest(error) => Some(error),
            Self::Scripts(error) => Some(error),
            Self::Renderer(error) => Some(error),
            Self::Cancelled => None,
        }
    }
}

impl From<GameProjectAssetIndexError> for GameApplicationError {
    fn from(error: GameProjectAssetIndexError) -> Self {
        Self::AssetIndex(error)
    }
}

impl From<AssetRegistryError> for GameApplicationError {
    fn from(error: AssetRegistryError) -> Self {
        Self::AssetCatalog(error)
    }
}

impl From<GameProjectSceneLoadError> for GameApplicationError {
    fn from(error: GameProjectSceneLoadError) -> Self {
        Self::SceneLoader(error)
    }
}

impl From<EditorSceneManifestLoadError> for GameApplicationError {
    fn from(error: EditorSceneManifestLoadError) -> Self {
        Self::SceneManifest(error)
    }
}

impl From<GameProjectScriptLoadError> for GameApplicationError {
    fn from(error: GameProjectScriptLoadError) -> Self {
        Self::Scripts(error)
    }
}

impl From<RhiError> for GameApplicationError {
    fn from(error: RhiError) -> Self {
        Self::Renderer(error)
    }
}

/// Swift's `GameApplication`.
pub struct GameApplication {
    pub engine: EngineHost,
    pub scene: EditorSceneAdapter,
    /// Called on the owner thread whenever the engine publishes a new surface.
    pub on_viewport_surface_changed: RefCell<Option<ViewportSurfaceChangedHandler>>,
    viewport_drawable_size: Cell<RenderDrawableSize>,
    last_viewport_surface: RefCell<ViewportSurfaceState>,
    pending_input_events: Mutex<Vec<InputEvent>>,
    frame_index: Cell<u64>,
    script_catalog_monitor: Option<ProjectScriptCatalogMonitor>,
    script_catalog_reload_elapsed: Cell<f64>,
    pub compiled_script_count: i64,
}

impl GameApplication {
    /// Swift's initializer. `project_directory: nil` selects the seeded
    /// preview scene, exactly like the Swift default argument.
    ///
    /// Swift created its own `EditorSceneAdapter()` here. This crate's manifest
    /// keeps `diffuse-scene` as a dev-dependency only, so the registry that
    /// `EditorSceneAdapter::new` requires cannot be named in library code; the
    /// caller supplies a freshly created adapter (`seed_preview_scene: true`)
    /// instead. Loading, scripting and engine wiring are unchanged.
    pub fn new(
        project_directory: Option<&Path>,
        render_device: Option<Arc<Device>>,
        in_game_ui: Option<Box<dyn InGameUIProviding>>,
        register_project_scripts: Option<ProjectScriptRegistrar>,
    ) -> Result<Self, GameApplicationError> {
        let scene = EditorSceneAdapter::new(
            true,
            ComponentRegistry::built_in(),
            EditorInspectorRendererRegistry::built_in(),
        );
        let script_loader = GameProjectScriptLoader::new();
        let mut compiled_script_count = register_project_scripts
            .as_ref()
            .map(|register| register(&scene.script_runtime))
            .unwrap_or(0);
        let mut script_catalog_monitor = None;

        if let Some(project_directory) = project_directory {
            let project_path = project_directory.to_string_lossy().into_owned();
            let preferred_mesh_indices = GameProjectAssetIndexLoader::load(project_directory)?;
            EditorAssetCatalog::load_project(&project_path, &preferred_mesh_indices)?;
            ProjectRuntimeResources::configure_audio_search_paths(
                scene.audio_engine.as_ref(),
                &project_path,
            );
            if let Some(manifest) = GameProjectSceneLoader::load(project_directory)? {
                let result = scene.load(&manifest);
                if let Some(error) = result.error {
                    return Err(error.into());
                }
            }
            let monitor = ProjectScriptCatalogMonitor::new(project_path);
            match monitor.load_if_changed(true) {
                Ok(Some(catalog)) => {
                    let report = scene.apply_project_script_catalog(&catalog);
                    Self::write_script_catalog_report(&report, &catalog.diagnostics, false);
                }
                Ok(None) => {}
                Err(error) => {
                    scene.apply_project_script_catalog(&ProjectScriptCatalog::built_in());
                    Self::report_diagnostic(format!("script catalog failed to load: {error}"));
                }
            }
            script_catalog_monitor = Some(monitor);
        } else {
            scene.apply_project_script_catalog(&ProjectScriptCatalog::built_in());
        }

        if let Some(project_directory) = project_directory {
            let entries = script_loader.load(project_directory, &scene.script_runtime)?;
            compiled_script_count += i64::try_from(entries.len()).unwrap_or(i64::MAX);
            for entry in &entries {
                scene.register_dynamic_script_option(
                    entry.identifier.clone(),
                    entry.display_name.clone(),
                    &entry.legacy_identifiers,
                );
            }
            let unresolved_bindings = scene.unresolved_script_binding_descriptions(true);
            if project_directory.join("build.json").is_file() && !unresolved_bindings.is_empty() {
                return Err(
                    GameProjectScriptLoadError::MissingBindings(unresolved_bindings).into(),
                );
            }
            for binding in unresolved_bindings {
                Self::report_diagnostic(format!("unresolved script binding: {binding}"));
            }
        }

        let engine = EngineHost::new(
            Arc::new(BridgedEngineRuntime::new()),
            render_device,
            in_game_ui,
        );
        Ok(GameApplication {
            engine,
            scene,
            on_viewport_surface_changed: RefCell::new(None),
            viewport_drawable_size: Cell::new(RenderDrawableSize::new(1280, 720)),
            last_viewport_surface: RefCell::new(ViewportSurfaceState::default()),
            pending_input_events: Mutex::new(Vec::new()),
            frame_index: Cell::new(0),
            script_catalog_monitor,
            script_catalog_reload_elapsed: Cell::new(0.0),
            compiled_script_count,
        })
    }

    /// Swift's initializer with every default argument.
    pub fn with_defaults() -> Result<Self, GameApplicationError> {
        Self::new(None, None, None, None)
    }

    /// Swift's `GameApplication(projectDirectory:)` with the other defaults.
    pub fn with_project_directory(project_directory: &Path) -> Result<Self, GameApplicationError> {
        Self::new(Some(project_directory), None, None, None)
    }

    pub fn viewport_drawable_size(&self) -> RenderDrawableSize {
        self.viewport_drawable_size.get()
    }

    pub fn set_viewport_drawable_size(&self, size: RenderDrawableSize) {
        if self.viewport_drawable_size.get() == size {
            return;
        }
        self.viewport_drawable_size.set(size);
    }

    /// Enqueues a platform input event for the next [`Self::tick`].
    pub fn enqueue_input(&self, event: InputEvent) {
        self.pending_input_events
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .push(event);
    }

    pub fn current_viewport_surface_state(&self) -> ViewportSurfaceState {
        self.engine.current_viewport_surface_state()
    }

    /// Starts simulation and the viewport-surface render thread.
    pub fn bootstrap(&self) {
        self.engine.start(None, true, None);
        self.engine
            .queue_render_settings(Self::default_render_settings());
    }

    /// Swift's `bootstrapPrepared(onProgress:)` without a cancellation probe.
    pub fn bootstrap_prepared(
        &self,
        on_progress: impl Fn(ResourcePreparationProgress) + Send + Sync + 'static,
    ) -> Result<(), GameApplicationError> {
        self.bootstrap_prepared_while(on_progress, || false)
    }

    /// [`Self::bootstrap_prepared`] with an explicit cancellation probe, the
    /// synchronous stand-in for Swift's `Task.checkCancellation()`. A cancelled
    /// preparation drops the prepared renderer without starting the engine.
    pub fn bootstrap_prepared_while(
        &self,
        on_progress: impl Fn(ResourcePreparationProgress) + Send + Sync + 'static,
        is_cancelled: impl Fn() -> bool,
    ) -> Result<(), GameApplicationError> {
        let settings = Self::default_render_settings();
        let renderer = self
            .engine
            .prepare_renderer(None, true, &settings, on_progress)?;
        if is_cancelled() {
            return Err(GameApplicationError::Cancelled);
        }
        let consumer: Option<Box<dyn RenderPacketConsumer>> =
            renderer.map(|renderer| Box::new(renderer) as Box<dyn RenderPacketConsumer>);
        self.engine.start(None, true, consumer);
        self.engine.queue_render_settings(settings);
        Ok(())
    }

    /// Advances one frame: script-catalog watch, scene simulation and the
    /// engine packet submission. Does nothing before [`Self::bootstrap`].
    pub fn tick(&self, delta_time: f64) {
        if !self.engine.is_started() {
            return;
        }
        let elapsed = self.script_catalog_reload_elapsed.get() + delta_time.max(0.0);
        if elapsed >= 1.0 {
            self.script_catalog_reload_elapsed.set(0.0);
            self.reload_project_scripts();
        } else {
            self.script_catalog_reload_elapsed.set(elapsed);
        }

        let events = std::mem::take(
            &mut *self
                .pending_input_events
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()),
        );

        let frame_index = self.frame_index.get().wrapping_add(1);
        self.frame_index.set(frame_index);
        self.scene
            .tick_scene(delta_time, frame_index, events.clone(), true);
        self.engine.tick(
            delta_time,
            events,
            self.viewport_drawable_size.get(),
            true,
            Some(self.scene.current_render_scene()),
            Some(self.scene.current_scene_snapshot()),
            Some(self.scene.current_joint_palette_map()),
            Some(self.scene.current_in_game_canvas()),
            Some(self.scene.make_particle_simulation_feedback_handler()),
            false,
        );

        let surface = self.engine.current_viewport_surface_state();
        let changed = *self.last_viewport_surface.borrow() != surface;
        if changed {
            self.last_viewport_surface.replace(surface.clone());
            let handler = self.on_viewport_surface_changed.borrow().clone();
            if let Some(handler) = handler {
                handler(surface);
            }
        }
    }

    pub fn shutdown(&self) {
        self.engine.shutdown();
    }

    /// Exercises exported gameplay in CI without opening a window or GPU device.
    pub fn simulate_frames(&self, count: i64) {
        self.simulate_frames_with_delta_time(count, 1.0 / 60.0);
    }

    /// [`Self::simulate_frames`] with Swift's explicit `deltaTime:` argument.
    pub fn simulate_frames_with_delta_time(&self, count: i64, delta_time: f64) {
        for _ in 0..count.max(0) {
            let frame_index = self.frame_index.get().wrapping_add(1);
            self.frame_index.set(frame_index);
            self.scene
                .tick_scene(delta_time, frame_index, Vec::new(), false);
        }
    }

    fn reload_project_scripts(&self) {
        let Some(monitor) = self.script_catalog_monitor.as_ref() else {
            return;
        };
        match monitor.load_if_changed(false) {
            Ok(Some(catalog)) => {
                let report = self.scene.apply_project_script_catalog(&catalog);
                Self::write_script_catalog_report(&report, &catalog.diagnostics, true);
            }
            Ok(None) => {}
            Err(error) => Self::report_diagnostic(format!("script catalog reload failed: {error}")),
        }
    }

    fn write_script_catalog_report(
        report: &EditorScriptCatalogApplyReport,
        diagnostics: &[ProjectScriptCatalogDiagnostic],
        report_unresolved_bindings: bool,
    ) {
        for diagnostic in diagnostics {
            Self::report_diagnostic(format!(
                "script catalog {}: {}",
                diagnostic.severity.raw_value(),
                diagnostic.message
            ));
        }
        if report_unresolved_bindings {
            for binding in &report.unresolved_bindings {
                Self::report_diagnostic(format!("unresolved script binding: {binding}"));
            }
        }
    }

    fn report_diagnostic(message: impl Into<String>) {
        LogSystem::logger(SCRIPT_LOG_TARGET).log(&LogEvent::new(Level::Warning, message.into()));
    }

    fn default_render_settings() -> RenderSettings {
        RenderSettings::configured(|settings| {
            settings.post_processing.fxaa = true;
            settings.shadows.enabled = true;
            settings.viewport.offscreen = true;
        })
    }
}
