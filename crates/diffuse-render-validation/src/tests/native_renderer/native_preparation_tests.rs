//! Ported from `Engine/Tests/NativeRendererTests/NativePreparationTests.swift`.
//!
//! GPU test: needs a usable native RHI device and the deployed
//! `DiffuseRuntime_RenderBackend` bundle (`COVE_RESOURCE_PATH`).

use std::sync::{Arc, Mutex};

use cove_graphics::rhi::ResourcePreparationProgress;

use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::tests::native_renderer::support::device;
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_render::RenderDrawableSize;
use diffuse_render::native::native_renderer::NativeRenderer;

/// A prepared renderer can render its initial settings without recompiling.
#[test]
fn prepared_renderer_renders_initial_settings() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = crate::tests::native_renderer::support::lock_serial();
    let Some(device) = device::make_for(device::platform_api(), false).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(64, 48), 0);
    packet.render_settings.shading.pbr = false;
    packet.render_settings.post_processing.fxaa = true;

    let events: Arc<Mutex<Option<ResourcePreparationProgress>>> = Arc::new(Mutex::new(None));
    let sink = events.clone();
    let mut renderer = NativeRenderer::prepared(
        &device,
        None,
        AssetRegistry::shared(),
        None,
        &packet.render_settings,
        &[],
        move |progress| {
            *sink
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(progress);
        },
    )
    .expect("prepared renderer");

    let last = events
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .clone()
        .expect("preparation progress");
    assert_eq!(last.phase, cove_graphics::rhi::PreparationPhase::Finished);
    assert_eq!(last.completed_steps, 8);
    assert!(device.pipeline_statistics().compute.cold.count > 0);

    let before = device.pipeline_statistics().cache_misses();
    renderer.render_checked(&packet).expect("render");
    device.wait_until_idle().expect("idle");

    assert!(renderer.color_texture().is_some());
    assert_eq!(
        device.pipeline_statistics().cache_misses(),
        before,
        "the initial scene must use the prepared pipeline variants"
    );
}
