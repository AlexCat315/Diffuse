//! Ported from `Editor/Tests/GameRuntimeTests/NativeGameApplicationTests.swift`.
//!
//! Swift ran this case on macOS only (`#if os(macOS)`) against Metal. Rust
//! implements it for every host through the platform graphics API and keeps the
//! `COVE_RUN_GPU_SMOKE_TESTS=1` gate the rest of the GPU suites use, because a
//! build machine without a usable driver must not fail the default test run.
//!
//! Swift marked the suite `.serialized`; the Rust tests share the process-wide
//! `BridgedEngineRuntime` bridge state, so they take the same single lock.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::Duration;

use cove_graphics::rhi::{Device, DeviceConfig, GraphicsApi, RhiResult};
use diffuse_engine::engine_core::EngineRenderCompletion;
use diffuse_kernel::input_event::{InputEvent, KeyEvent, KeyModifiers};
use diffuse_render::RenderDrawableSize;
use diffuse_scene::input_action::Scancode;

use crate::game_application::GameApplication;

static SERIAL: Mutex<()> = Mutex::new(());

fn lock_serial() -> MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(|error| error.into_inner())
}

struct TempDirectory {
    url: PathBuf,
}

impl TempDirectory {
    fn new(prefix: &str) -> Self {
        let url =
            std::env::temp_dir().join(format!("{prefix}-{}", diffuse_kernel::codable::new_uuid()));
        std::fs::create_dir_all(&url).expect("temporary directory");
        TempDirectory { url }
    }

    fn path(&self) -> &Path {
        &self.url
    }

    fn write(&self, relative: &str, contents: &str) -> PathBuf {
        let url = self.url.join(relative);
        if let Some(parent) = url.parent() {
            std::fs::create_dir_all(parent).expect("parent directory");
        }
        std::fs::write(&url, contents).expect("fixture file");
        url
    }
}

impl Drop for TempDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.url);
    }
}

fn platform_api() -> GraphicsApi {
    #[cfg(target_os = "macos")]
    {
        GraphicsApi::Metal
    }
    #[cfg(target_os = "windows")]
    {
        GraphicsApi::Dx12
    }
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        GraphicsApi::Vulkan
    }
}

/// `RendererTestDevice.make(_:)` from the shared GPU-suite support: `None` where
/// Swift's test would have been skipped. The renderer also needs the deployed
/// `DiffuseRuntime_RenderBackend` bundle, which the GPU suites gate on
/// `COVE_RESOURCE_PATH`.
fn make_test_device() -> RhiResult<Option<Device>> {
    if std::env::var("COVE_RUN_GPU_SMOKE_TESTS").as_deref() != Ok("1")
        || std::env::var_os("COVE_RESOURCE_PATH").is_none()
    {
        return Ok(None);
    }
    Device::make(DeviceConfig {
        preferred_backends: vec![platform_api()],
        enable_validation: true,
        frames_in_flight: 2,
        ..DeviceConfig::default()
    })
    .map(Some)
}

#[test]
fn native_viewport() -> Result<(), Box<dyn std::error::Error>> {
    let _serial = lock_serial();
    let Some(device) = make_test_device()? else {
        return Ok(());
    };
    let device = Arc::new(device);
    let app = GameApplication::new(None, Some(device.clone()), None, None)?;
    let completed = Arc::new((Mutex::new(false), Condvar::new()));

    app.set_viewport_drawable_size(RenderDrawableSize::new(128, 96));
    app.bootstrap();
    let signal = completed.clone();
    app.engine.set_render_completion_handler(Some(Arc::new(
        move |_completion: EngineRenderCompletion| {
            *signal.0.lock().unwrap_or_else(|error| error.into_inner()) = true;
            signal.1.notify_all();
        },
    )));

    app.tick(1.0 / 60.0);

    let (lock, condition) = &*completed;
    let done = lock.lock().unwrap_or_else(|error| error.into_inner());
    let (done, timeout) = condition
        .wait_timeout_while(done, Duration::from_secs(45), |done| !*done)
        .unwrap_or_else(|error| error.into_inner());
    assert!(!timeout.timed_out(), "render completion timed out");
    assert!(*done);
    drop(done);

    let surface = app.current_viewport_surface_state();
    assert!(surface.is_valid(), "viewport surface is invalid");
    assert_eq!(surface.region.size, app.viewport_drawable_size());
    let resource = surface
        .image
        .as_ref()
        .expect("viewport surface has an image")
        .resource
        .clone();
    assert!(Arc::ptr_eq(resource.device(), &device));

    app.shutdown();
    Ok(())
}

/// Rust-only coverage for the paths the GPU case leaves ungated when no device
/// is available: project loading, the compiled-script count, the input queue,
/// the one-second `Scripts/scripts.json` reload and `simulateFrames`.
#[test]
fn headless_host_loads_project_and_reloads_catalog() -> Result<(), Box<dyn std::error::Error>> {
    let _serial = lock_serial();
    let project = TempDirectory::new("cove-game-host");
    let catalog_path = project.write(
        "Scripts/scripts.json",
        r#"{"schemaVersion":1,"scripts":[{"id":"test.spinner","displayName":"Spinner","preset":"rotator","defaultParameters":{}}]}"#,
    );

    let app = GameApplication::with_project_directory(project.path())?;
    assert_eq!(app.compiled_script_count, 0);
    assert_eq!(
        app.viewport_drawable_size(),
        RenderDrawableSize::new(1280, 720)
    );
    app.set_viewport_drawable_size(RenderDrawableSize::new(640, 480));
    assert_eq!(
        app.viewport_drawable_size(),
        RenderDrawableSize::new(640, 480)
    );
    assert!(
        app.scene
            .script_catalog_entries
            .borrow()
            .iter()
            .any(|entry| entry.identifier == "test.spinner")
    );

    app.bootstrap();
    let event = InputEvent::KeyDown(KeyEvent {
        scancode: Scancode::SPACE,
        keycode: Scancode::SPACE,
        modifiers: KeyModifiers::default(),
        is_repeat: false,
    });
    app.enqueue_input(event.clone());
    app.tick(1.0 / 60.0);
    assert_eq!(app.engine.current_input_events(), vec![event]);

    std::fs::write(
        &catalog_path,
        r#"{"schemaVersion":1,"scripts":[{"id":"test.spinner","displayName":"Spinner","preset":"rotator","defaultParameters":{}},{"id":"test.slider","displayName":"Slider","preset":"mover","defaultParameters":{}}]}"#,
    )?;
    app.tick(1.0);
    assert!(
        app.scene
            .script_catalog_entries
            .borrow()
            .iter()
            .any(|entry| entry.identifier == "test.slider")
    );

    app.simulate_frames(2);
    app.shutdown();
    Ok(())
}
