//! Standalone game player and exported-project validation.

use std::cell::{Cell, RefCell};
use std::error::Error;
use std::io::{self, Write};
use std::path::Path;
use std::process::ExitCode;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::thread::{self, JoinHandle};

use cove_graphics::rhi::{
    Device, DeviceConfig, GraphicsApi, ResourcePreparationContext, ResourcePreparationProgress,
    RhiError,
};
use cove_logging::{Level, LogEvent, LogSystem, LoggingConfiguration};
use cove_ui::composition::HorizontalAlignment;
use cove_ui::core::content_scale;
use cove_ui::hosts::desktop::application::AppFrameDrivePolicy;
use cove_ui::hosts::{Application, ApplicationCallbacks, ApplicationConfiguration};
use cove_ui_compose::prelude::{
    AnyView, Button, Column, LayoutFrameExt, ProgressView, Scope, SemanticFontRef,
    SemanticStyleViewExt, Spinner, State, Text, TupleView, View, ViewExt, ZStack,
};
use diffuse_editor_core::rendering::hud::in_game_ui_host::InGameUIHost;
use diffuse_editor_core::rendering::viewport::viewport_host::ViewportHost;
use diffuse_game_runtime::game_application::{GameApplication, GameApplicationError};
use diffuse_game_runtime::game_project_directory_resolver::GameProjectDirectoryResolver;
use diffuse_game_runtime::player_install_validator::PlayerInstallValidator;
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::surface::viewport_surface::ViewportSurfaceState;

const LOG_TARGET: &str = "com.cove.player";

#[derive(Clone, PartialEq)]
enum PreparationState {
    Preparing(Option<ResourcePreparationProgress>),
    Ready,
    Failed(String),
    Cancelled,
}

type PreparedRenderer = Result<Option<NativeRenderer>, GameApplicationError>;

struct PreparationTask {
    cancel: Arc<AtomicBool>,
    progress: Receiver<ResourcePreparationProgress>,
    worker: JoinHandle<PreparedRenderer>,
}

struct PlayerState {
    app: Rc<GameApplication>,
    preparation: State<PreparationState>,
    task: RefCell<Option<PreparationTask>>,
    surface: State<ViewportSurfaceState>,
    logical_size: Cell<(u32, u32)>,
}

impl PlayerState {
    fn new(app: Rc<GameApplication>) -> Self {
        Self {
            app,
            preparation: State::new(PreparationState::Preparing(None)),
            task: RefCell::new(None),
            surface: State::new(ViewportSurfaceState::default()),
            logical_size: Cell::new((1280, 720)),
        }
    }

    fn start_preparation(&self) {
        self.preparation.set(PreparationState::Preparing(None));
        if self.task.borrow().is_some() {
            // A cancelled worker is still releasing its GPU resources.
            return;
        }
        let engine = self.app.engine.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let worker_cancel = cancel.clone();
        let (progress_tx, progress) = mpsc::channel();
        let worker = thread::Builder::new()
            .name("player-shader-preparation".into())
            .spawn(move || {
                let result = GameApplication::prepare_viewport_renderer(&engine, move |value| {
                    if worker_cancel.load(Ordering::Acquire) {
                        if let Some(context) = ResourcePreparationContext::current() {
                            context.cancel();
                        }
                    } else {
                        let _ = progress_tx.send(value);
                    }
                });
                match result {
                    Err(GameApplicationError::Renderer(RhiError::Cancelled)) => {
                        Err(GameApplicationError::Cancelled)
                    }
                    result => result,
                }
            });
        match worker {
            Ok(worker) => {
                self.task.replace(Some(PreparationTask {
                    cancel,
                    progress,
                    worker,
                }));
            }
            Err(error) => self.fail_preparation(error.to_string()),
        }
    }

    fn fail_preparation(&self, message: String) {
        LogSystem::logger(LOG_TARGET).log(&LogEvent::new(
            Level::Error,
            format!("Shader preparation failed: {message}"),
        ));
        self.preparation.set(PreparationState::Failed(message));
    }

    fn cancel_preparation(&self) {
        if let Some(task) = self.task.borrow().as_ref() {
            task.cancel.store(true, Ordering::Release);
        }
        self.preparation.set(PreparationState::Cancelled);
    }

    fn poll_preparation(&self) {
        let mut slot = self.task.borrow_mut();
        let Some(task) = slot.as_ref() else {
            return;
        };
        let cancelled = task.cancel.load(Ordering::Acquire);
        if !cancelled && let Some(progress) = task.progress.try_iter().last() {
            self.preparation
                .set(PreparationState::Preparing(Some(progress)));
        }
        if !task.worker.is_finished() {
            return;
        }
        let task = slot.take().expect("polled preparation task");
        drop(slot);
        let result = task.worker.join();
        if cancelled {
            if matches!(self.preparation.get(), PreparationState::Preparing(_)) {
                drop(result);
                self.start_preparation();
            }
            return;
        }
        match result {
            Ok(Ok(renderer)) => {
                self.app.start_prepared_renderer(renderer);
                self.preparation.set(PreparationState::Ready);
            }
            Ok(Err(GameApplicationError::Cancelled)) => {
                self.preparation.set(PreparationState::Cancelled);
            }
            Ok(Err(error)) => self.fail_preparation(error.to_string()),
            Err(_) => self.fail_preparation("Shader preparation worker stopped.".into()),
        }
    }

    fn shutdown(&self) {
        if let Some(task) = self.task.borrow_mut().take() {
            task.cancel.store(true, Ordering::Release);
            let _ = task.worker.join();
        }
        self.app.shutdown();
    }
}

struct PlayerRoot(Rc<PlayerState>);

impl View for PlayerRoot {
    fn body(&self, _scope: &Scope) -> AnyView {
        let state = &self.0;
        let mut content = Vec::new();
        match state.preparation.get() {
            PreparationState::Ready => {
                let input_app = state.app.clone();
                let size_app = state.app.clone();
                let size_state = state.clone();
                return ViewportHost::without_overlay(state.surface.get())
                    .automatically_focus(true)
                    .on_input_event(Rc::new(move |event| input_app.enqueue_input(event)))
                    .on_drawable_size_change(Rc::new(move |size| {
                        size_app.set_viewport_drawable_size(size);
                    }))
                    .on_screen_frame_change(Rc::new(move |frame| {
                        size_state
                            .logical_size
                            .set((frame.width.round() as u32, frame.height.round() as u32));
                    }))
                    .fill()
                    .erased();
            }
            PreparationState::Preparing(progress) => {
                content.push(Spinner::new().size(18.0).erased());
                content.push(Text::new("Preparing shaders…").erased());
                if let Some(progress) = progress {
                    let fraction = progress.fraction();
                    if let Some(step) = progress.current_step {
                        content.push(
                            Text::new(step)
                                .semantic_font(SemanticFontRef::caption())
                                .erased(),
                        );
                    }
                    if let Some(fraction) = fraction {
                        content.push(
                            ProgressView::new(Some(fraction))
                                .frame_width(240.0)
                                .erased(),
                        );
                    }
                }
                let state = state.clone();
                content.push(Button::title("Cancel", move || state.cancel_preparation()).erased());
            }
            PreparationState::Failed(message) => {
                content.push(Text::new("Shader preparation failed").erased());
                content.push(
                    Text::new(message)
                        .semantic_font(SemanticFontRef::caption())
                        .erased(),
                );
            }
            PreparationState::Cancelled => {
                content.push(Text::new("Shader preparation cancelled").erased());
            }
        }
        if matches!(
            state.preparation.get(),
            PreparationState::Failed(_) | PreparationState::Cancelled
        ) {
            let state = state.clone();
            content.push(Button::title("Retry", move || state.start_preparation()).erased());
        }
        let content = Column::new(
            HorizontalAlignment::Center,
            12.0,
            AnyView::new(TupleView::new(content)),
        );
        ZStack::new(content).fill().erased()
    }
}

fn make_render_device(arguments: &[String]) -> Result<Arc<Device>, Box<dyn Error>> {
    let requested = match arguments
        .iter()
        .position(|argument| argument == "--renderer")
    {
        Some(index) => arguments
            .get(index + 1)
            .cloned()
            .ok_or("--renderer requires native, metal, vulkan, or dx12.")?,
        None => std::env::var("COVE_RENDERER").unwrap_or_else(|_| "native".into()),
    };
    let mut config = DeviceConfig {
        frames_in_flight: 3,
        ..DeviceConfig::default()
    };
    match requested.to_ascii_lowercase().as_str() {
        "native" => {}
        "metal" => config.preferred_backends = vec![GraphicsApi::Metal],
        "vulkan" => config.preferred_backends = vec![GraphicsApi::Vulkan],
        "dx12" | "d3d12" => config.preferred_backends = vec![GraphicsApi::Dx12],
        _ => return Err(format!("Unknown renderer '{requested}'.").into()),
    }
    Ok(Arc::new(Device::make(config)?))
}

fn run_player(arguments: &[String], project: Option<&Path>) -> Result<(), Box<dyn Error>> {
    let device = make_render_device(arguments)?;
    let hud = InGameUIHost::new(device.clone())?;
    let app = Rc::new(GameApplication::new(
        project,
        Some(device.clone()),
        Some(hud.render_provider()),
        None,
    )?);
    let state = Rc::new(PlayerState::new(app.clone()));
    let surface = state.surface.clone();
    app.on_viewport_surface_changed
        .replace(Some(Rc::new(move |value| surface.set(value))));
    state.start_preparation();

    let mut config = ApplicationConfiguration::new(Some("Cove Player"));
    config.rendering.clear_color = [0.0, 0.0, 0.0, 1.0];
    config.frames.policy = AppFrameDrivePolicy::Continuous;
    config.frames.target_rate = Some(60.0);
    let tick_state = state.clone();
    let callbacks = ApplicationCallbacks {
        tick: Some(Rc::new(move |delta_time| {
            tick_state.poll_preparation();
            if tick_state.preparation.get() == PreparationState::Ready {
                app.tick(delta_time);
                let (width, height) = tick_state.logical_size.get();
                hud.tick(
                    width,
                    height,
                    content_scale().max(1.0),
                    app.scene.current_in_game_canvas(),
                );
            }
        })),
        ..ApplicationCallbacks::default()
    };
    let result = Application::run(
        config,
        Some(device),
        PlayerRoot(state.clone()).erased(),
        callbacks,
    );
    state.shutdown();
    Ok(result?)
}

fn validate_project(arguments: &[String], project: Option<&Path>) -> Result<(), Box<dyn Error>> {
    let project = project.ok_or("Project validation requires --project <directory>.")?;
    let frames = match arguments
        .iter()
        .position(|argument| argument == "--simulation-frames")
    {
        Some(index) => arguments
            .get(index + 1)
            .and_then(|value| value.parse::<i64>().ok())
            .filter(|count| (0..=600).contains(count))
            .ok_or("--simulation-frames must be between 0 and 600.")?,
        None => 0,
    };
    let app = GameApplication::with_project_directory(project)?;
    app.simulate_frames(frames);
    writeln!(
        io::stdout().lock(),
        "CovePlayer project validation passed ({} compiled scripts, {} entities, {frames} simulation frames)",
        app.compiled_script_count,
        app.scene.manifest().entity_count,
    )?;
    Ok(())
}

fn main() -> ExitCode {
    let result = (|| -> Result<(), Box<dyn Error>> {
        let mut logging = LoggingConfiguration::default();
        logging.apply_process_environment()?;
        LogSystem::bootstrap(Some("CovePlayer"), logging, None)?;
        let arguments = std::env::args().collect::<Vec<_>>();
        let project = GameProjectDirectoryResolver::resolve_default();
        let project = project.as_deref().map(Path::new);
        if arguments
            .iter()
            .any(|argument| argument == "--validate-project")
        {
            validate_project(&arguments, project)
                .map_err(|error| format!("[CovePlayer] project validation failed: {error}").into())
        } else if arguments
            .iter()
            .any(|argument| argument == "--validate-install")
        {
            let report = PlayerInstallValidator::validate_layout_default()?;
            writeln!(io::stdout().lock(), "{report}")?;
            Ok(())
        } else {
            run_player(&arguments, project)
                .map_err(|error| format!("[CovePlayer] startup failed: {error}").into())
        }
    })();
    let exit = match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            LogSystem::logger(LOG_TARGET).log(&LogEvent::new(Level::Error, error.to_string()));
            ExitCode::FAILURE
        }
    };
    LogSystem::flush();
    exit
}
