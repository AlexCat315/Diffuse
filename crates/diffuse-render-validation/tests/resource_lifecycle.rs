use std::sync::{Arc, Mutex};

use cove_graphics::rhi::{Device, DeviceConfig, PreparationPhase};
use cove_logging::{Level, LogEvent, LogSystem};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::{RenderDrawableSize, RenderSettings};
use diffuse_render_validation::probes::mesh_probe_scene::MeshProbeScene;
use diffuse_render_validation::reference::{grid_image::GridImage, scene_capture::SceneCapture};

fn device() -> Option<Arc<Device>> {
    match Device::make(DeviceConfig::default()) {
        Ok(device) => Some(Arc::new(device)),
        Err(error) => {
            LogSystem::logger("com.cove.tests").log(&LogEvent::new(
                Level::Warning,
                format!("GPU unavailable; skipping renderer lifecycle regression: {error}"),
            ));
            None
        }
    }
}

#[test]
fn viewport_and_mips_survive_resize_and_renderer_drop() {
    let Some(device) = device() else { return };
    let renderer = NativeRenderer::new(
        &device,
        None,
        AssetRegistry::shared(),
        None,
        &RenderSettings::default(),
        &[64],
    )
    .expect("renderer");
    let mut capture = SceneCapture { device, renderer };
    let size = RenderDrawableSize::new(64, 64);
    let mut packet = MeshProbeScene::packet(size, 0);
    packet.mipmapped_viewport_output = true;
    capture.render(&packet).expect("first frame with mips");
    let surface = capture.renderer.current_viewport_surface_state();
    let image = surface.image.as_ref().expect("published image");
    assert_eq!(image.mipmaps.len(), 6);
    let pixels = capture.readback().expect("first output");
    let mip = image.mipmaps.last().expect("last mip");
    let mip_pixels = GridImage::readback(
        &capture.device,
        mip.texture(),
        RenderDrawableSize::new(1, 1),
    )
    .expect("first mip");

    packet.drawable_size = RenderDrawableSize::new(520, 64);
    packet.frame_index = 1;
    capture.render(&packet).expect("frame after growth");
    let replacement = capture.renderer.current_viewport_surface_state();
    assert!(!Arc::ptr_eq(
        &image.resource,
        &replacement.image.as_ref().expect("replacement").resource,
    ));
    capture.finish().expect("completed frames");
    let device = capture.device.clone();
    drop(capture);

    assert_eq!(
        GridImage::readback(&device, image.resource.texture(), size).expect("retained output"),
        pixels,
    );
    assert_eq!(
        GridImage::readback(&device, mip.texture(), RenderDrawableSize::new(1, 1))
            .expect("retained mip"),
        mip_pixels,
    );
}

#[test]
fn prepared_renderer_reports_all_eight_stages() {
    let Some(device) = device() else { return };
    if !device.supports_background_compilation() {
        LogSystem::logger("com.cove.tests").log(&LogEvent::new(
            Level::Warning,
            "backend has no background compilation; skipping preparation regression",
        ));
        return;
    }
    let progress = Arc::new(Mutex::new(Vec::new()));
    let recorded = progress.clone();
    let mut renderer = NativeRenderer::prepared(
        &device,
        None,
        AssetRegistry::shared(),
        None,
        &RenderSettings::default(),
        &[64],
        move |event| recorded.lock().expect("progress lock").push(event),
    )
    .expect("prepared renderer");
    renderer
        .render_checked(&MeshProbeScene::packet(RenderDrawableSize::new(64, 64), 0))
        .expect("prepared first frame");
    device.wait_until_idle().expect("completed first frame");
    let events = progress.lock().expect("progress lock");
    let last = events.last().expect("preparation events");
    assert_eq!(last.phase, PreparationPhase::Finished);
    assert_eq!(last.completed_steps, 8);
    assert_eq!(last.total_steps, Some(8));
    for stage in [
        "Meshes",
        "Materials",
        "Lighting",
        "Shadows",
        "HDR",
        "Grid",
        "Post-processing",
        "Particles",
    ] {
        assert!(
            events
                .iter()
                .any(|event| event.current_step.as_deref() == Some(stage)),
            "{stage}"
        );
    }
}
