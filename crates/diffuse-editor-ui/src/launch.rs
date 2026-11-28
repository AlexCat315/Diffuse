//! Editor process entry points from `Editor/Sources/EditorUI/Launch.swift`.

use std::collections::BTreeMap;
use std::io::{self, Write};
use std::process::ExitCode;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use cove_graphics::rhi::{Device, DeviceConfig, GraphicsApi};
use cove_logging::{Level, LogEvent, LogSystem, LogValue, LoggingConfiguration};
use cove_ui::hosts::desktop::{AppWindowTitleBarStyle, Application, ApplicationCallbacks};
use cove_ui::hosts::desktop::diagnostics::{devtools, integration};
use cove_ui::ApplicationConfiguration;
use cove_ui_compose::AnyView;
use cove_ui_compose::app_storage::{AppStorageDefaults, FileAppStorageStore};
use diffuse_card_battle::core::battle_state_machine::BattleStateMachine;
use diffuse_card_battle::rules::battle_command::BattleCommand;
use diffuse_card_battle::support::battle_hud_snapshot::BattleHUDSnapshot;
use diffuse_card_battle::support::battle_identifiers::BattlePlayerID;
use diffuse_card_battle::support::battle_sample_factory::BattleSampleFactory;
use diffuse_editor_core::rendering::hud::in_game_ui_host::InGameUIHost;
use diffuse_editor_core::application::editor_application::EditorApplication;
use diffuse_editor_core::state::editor_state::PlaybackState;
use diffuse_intent::invocation::capability_invocation::ConfirmationSeverity;

use crate::hud::battle_hud_model::BattleHUDModel;
use crate::hud::in_game_battle_hud_view::InGameBattleHUDView;
use crate::launch_options::EditorAppLaunchOptions;
use crate::projects::editor_launch_context::EditorLaunchContext;
use crate::root::editor_launch_root::EditorLaunchRoot;
use crate::root::root_view_factory::persistence_directory;
use crate::release_install_validator::EditorInstallValidator;

const LOG_TARGET: &str = "com.cove.editor";
const SIMULATION_STEP: Duration = Duration::from_nanos(16_666_667);
const REVIEW_INTERVAL: Duration = Duration::from_millis(100);
static STOP_REQUESTED: AtomicBool = AtomicBool::new(false);

pub fn run() -> ExitCode {
    let arguments = std::env::args().collect::<Vec<_>>();
    let environment = std::env::vars().collect();
    let result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let mut logging = LoggingConfiguration::default();
        logging.apply_process_environment()?;
        LogSystem::bootstrap(Some("Diffuse"), logging, None)?;
        run_editor(&arguments, &environment)
    })();
    LogSystem::flush();
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            LogSystem::logger(LOG_TARGET).log(&LogEvent::new(Level::Error, error.to_string()));
            LogSystem::flush();
            ExitCode::FAILURE
        }
    }
}

fn run_editor(
    arguments: &[String],
    environment: &BTreeMap<String, String>,
) -> Result<(), Box<dyn std::error::Error>> {
    let options = EditorAppLaunchOptions::load(arguments, environment)?;
    if options.validate_install {
        let report = EditorInstallValidator::validate_editor_layout_default()?;
        writeln!(io::stdout().lock(), "{report}")?;
        return Ok(());
    }
    let flag = |name: &str| arguments.iter().any(|argument| argument == name);
    if flag("--mcp-headless") {
        let directory = options
            .project_directory
            .ok_or("--mcp-headless requires --project-dir <directory>.")?;
        install_headless_shutdown_handler()?;
        let app = EditorApplication::new(directory.clone())?;
        let editor = HeadlessEditor {
            app,
            frame_index: 0,
        };
        editor.app.enable_bundled_plugins();
        editor.app.open_scene_manifest();
        if flag("--trust-project-scripts") {
            editor.app.workstation.scripts.set_project_trusted(true);
        }
        if EditorAppLaunchOptions::watch_plugin_packages_requested(arguments, environment) {
            editor
                .app
                .start_watching_plugin_packages(Duration::from_secs(1));
        }
        let port = editor.app.start_mcp_bridge()?;
        LogSystem::logger(LOG_TARGET).log(
            &LogEvent::new(Level::Info, "Headless editor ready").with_metadata(BTreeMap::from([
                ("project".to_owned(), LogValue::String(directory)),
                ("port".to_owned(), LogValue::String(port.to_string())),
            ])),
        );
        LogSystem::flush();
        editor.run(flag("--approve-scene-edits"));
        return Ok(());
    }
    run_desktop(arguments, environment, options)
}

fn run_desktop(
    arguments: &[String],
    environment: &BTreeMap<String, String>,
    options: EditorAppLaunchOptions,
) -> Result<(), Box<dyn std::error::Error>> {
    let settings_requested = EditorAppLaunchOptions::settings_requested(arguments);
    let state_directory = persistence_directory(environment.get("COVE_EDITOR_STATE_DIRECTORY").map(String::as_str))?;
    AppStorageDefaults::set_store(Arc::new(FileAppStorageStore::new(state_directory.join("app-storage.json"))));
    let device = Arc::new(Device::make(editor_render_configuration(arguments, environment, options.backend_config)?)?);
    let in_game_ui = InGameUIHost::new(device.clone())?;
    if environment.get("COVE_EDITOR_SAMPLE_HUD").is_some_and(|value| value == "1") {
        let battle = BattleStateMachine::reduce(
            &BattleSampleFactory::make_three_kingdoms_duel(),
            &BattleCommand::StartPlayerTurn { draw_count: 4 },
        );
        if let Some(snapshot) = BattleHUDSnapshot::make(&battle, &BattlePlayerID::player()) {
            in_game_ui.set_root_view(InGameBattleHUDView::new(Rc::new(BattleHUDModel::new(snapshot))));
        }
    }
    let context = EditorLaunchContext::new(
        device.clone(), in_game_ui, state_directory, settings_requested,
        EditorAppLaunchOptions::watch_plugin_packages_requested(arguments, environment),
        EditorAppLaunchOptions::review_plugin_path(arguments),
    );
    context.restore_projects(options.project_directory.as_deref());
    let mut config = ApplicationConfiguration::new(Some("Diffuse"));
    config.rendering.clear_color = [30.0 / 255.0, 31.0 / 255.0, 34.0 / 255.0, 1.0];
    config.window.title_bar_style = if settings_requested {
        AppWindowTitleBarStyle::Standard
    } else {
        AppWindowTitleBarStyle::HiddenInset
    };
    if settings_requested {
        config.window.width = 1040;
        config.window.height = 780;
    }
    integration::set_diagnostics_factory(Some(devtools::factory()));
    let result = Application::run(
        config,
        Some(device),
        AnyView::new(EditorLaunchRoot::new(context.clone(), settings_requested)),
        ApplicationCallbacks {
            events: context.events.clone(),
            tick: Some(Rc::new({
                let context = context.clone();
                move |elapsed| context.tick(elapsed)
            })),
            ready: Some(Rc::new({
                let context = context.clone();
                move |display| context.wire_display(display)
            })),
            ..ApplicationCallbacks::default()
        },
    );
    integration::set_diagnostics_factory(None);
    context.shutdown();
    Ok(result?)
}

fn editor_render_configuration(
    arguments: &[String],
    environment: &BTreeMap<String, String>,
    mut config: DeviceConfig,
) -> Result<DeviceConfig, Box<dyn std::error::Error>> {
    let requested = match arguments.iter().position(|value| value == "--renderer") {
        Some(index) => arguments.get(index + 1).map(String::as_str)
            .ok_or("--renderer requires native, metal, vulkan, or dx12.")?,
        None => environment.get("COVE_RENDERER").map(String::as_str).unwrap_or("native"),
    };
    let api = match requested.to_ascii_lowercase().as_str() {
        "native" => return Ok(config),
        "metal" => GraphicsApi::Metal,
        "vulkan" => GraphicsApi::Vulkan,
        "dx12" | "d3d12" => GraphicsApi::Dx12,
        _ => return Err(format!("Unknown renderer '{requested}'.").into()),
    };
    config.preferred_backends = vec![api];
    Ok(config)
}

struct HeadlessEditor {
    app: Rc<EditorApplication>,
    frame_index: u64,
}

impl HeadlessEditor {
    fn run(mut self, approve_scene_edits: bool) {
        let mut previous = Instant::now();
        let mut next_frame = previous;
        let mut next_review = previous + REVIEW_INTERVAL;
        while self.app.is_active() && !STOP_REQUESTED.load(Ordering::Relaxed) {
            let now = Instant::now();
            self.app.tick(now.duration_since(previous).as_secs_f64());
            previous = now;
            if self.app.store.playback_state() == PlaybackState::Playing {
                self.frame_index = self.frame_index.wrapping_add(1);
                self.app
                    .scene
                    .tick_scene(1.0 / 60.0, self.frame_index, Vec::new(), false);
            }
            if approve_scene_edits && now >= next_review {
                if self
                    .app
                    .store
                    .pending_confirmation_request()
                    .is_some_and(|request| {
                        request
                            .questions
                            .iter()
                            .all(|question| question.severity != ConfirmationSeverity::Destructive)
                    })
                {
                    self.app.accept_pending_confirmation();
                }
                next_review = now + REVIEW_INTERVAL;
            }
            next_frame += SIMULATION_STEP;
            let now = Instant::now();
            if let Some(delay) = next_frame.checked_duration_since(now) {
                std::thread::sleep(delay);
            } else {
                next_frame = now;
            }
        }
    }
}

impl Drop for HeadlessEditor {
    fn drop(&mut self) {
        self.app.shutdown();
        LogSystem::flush();
    }
}

#[cfg(unix)]
fn install_headless_shutdown_handler() -> io::Result<()> {
    unsafe extern "C" {
        fn signal(number: std::ffi::c_int, handler: extern "C" fn(std::ffi::c_int)) -> usize;
    }
    extern "C" fn stop(_: std::ffi::c_int) {
        STOP_REQUESTED.store(true, Ordering::Relaxed);
    }
    for number in [2, 15] {
        // SIGINT and SIGTERM on the supported Unix hosts.
        // SAFETY: the handler has the C signal ABI and performs a lock-free atomic store.
        if unsafe { signal(number, stop) } == usize::MAX {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

#[cfg(windows)]
fn install_headless_shutdown_handler() -> io::Result<()> {
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn SetConsoleCtrlHandler(handler: extern "system" fn(u32) -> i32, add: i32) -> i32;
    }
    extern "system" fn stop(event: u32) -> i32 {
        // CTRL_C_EVENT, CTRL_BREAK_EVENT and CTRL_CLOSE_EVENT.
        if event <= 2 {
            STOP_REQUESTED.store(true, Ordering::Relaxed);
            return 1;
        }
        0
    }
    // SAFETY: the callback follows the Win32 console-handler ABI and stays valid for the process lifetime.
    if unsafe { SetConsoleCtrlHandler(stop, 1) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}
