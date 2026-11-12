//! Ported from `Engine/Tests/NativeRendererTests/NativeViewportSurfaceTests.swift`.
//!
//! The Swift file is `#if os(macOS)` (it relies on `ARC` weak references and on
//! Metal's swapchain-free offscreen path); the Rust port uses `Weak` and the
//! backend-neutral offscreen targets, so it runs on every platform.

use std::sync::Arc;
use std::time::Duration;

use cove_graphics::rhi::{TextureDescriptor, TextureFormat, TextureResource, TextureUsage};
use diffuse_math::simd::simd_compat::Float2;
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::native::passes::native_grid_renderer::NativeGridRenderer;
use diffuse_render::surface::viewport_image::ViewportImage;
use diffuse_render::surface::viewport_surface::{ViewportSamplingRegion, ViewportSurfaceState};
use diffuse_render::{RenderDrawableSize, RenderSettings, ViewportTargetSizing};

use crate::probes::grid_probe_scene::GridProbeScene;
use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::reference::grid_image::GridImage;
use crate::tests::native_renderer::support::{device, lock_serial};

/// A settled shrink replaces targets but a held image stays readable.
#[test]
fn settled_shrink_replaces_targets_without_invalidating_held_image() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, true).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let mut renderer = NativeRenderer::new(
        &device,
        None,
        diffuse_assets::asset_registry::AssetRegistry::shared(),
        None,
        &RenderSettings::new(),
        &[],
    )
    .expect("renderer");
    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(1024, 1024), 0);
    renderer.render_checked(&packet).expect("large frame");
    let original = renderer.current_viewport_surface_state();
    packet.drawable_size = RenderDrawableSize::new(64, 64);
    renderer.render_checked(&packet).expect("small frame");
    assert!(Arc::ptr_eq(
        renderer
            .current_viewport_surface_state()
            .image
            .as_ref()
            .expect("current image"),
        original.image.as_ref().expect("original image")
    ));
    let held = original
        .image
        .as_ref()
        .expect("original image")
        .resource
        .clone();
    let pixels =
        GridImage::readback(&device, held.texture(), packet.drawable_size).expect("readback");

    std::thread::sleep(Duration::from_secs_f64(
        ViewportTargetSizing::SETTLE_INTERVAL + 0.1,
    ));
    renderer.render_checked(&packet).expect("settled frame");
    let compact = renderer.current_viewport_surface_state();
    assert_eq!(compact.region.capacity, RenderDrawableSize::new(256, 256));
    assert!(!Arc::ptr_eq(
        compact.image.as_ref().expect("compact image"),
        original.image.as_ref().expect("original image")
    ));
    assert_eq!(
        GridImage::readback(&device, held.texture(), packet.drawable_size).expect("held readback"),
        pixels
    );

    device.wait_until_idle().expect("idle");
}

/// Publication tracks the used region and only successful submissions.
#[test]
fn scene_publication_tracks_used_region_and_submission() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, true).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let mut renderer = NativeRenderer::new(
        &device,
        None,
        diffuse_assets::asset_registry::AssetRegistry::shared(),
        None,
        &RenderSettings::new(),
        &[],
    )
    .expect("renderer");
    let mut packet = MeshProbeScene::packet(RenderDrawableSize::new(96, 64), 0);
    renderer.render_checked(&packet).expect("first frame");
    let first = renderer.current_viewport_surface_state();
    assert!(first.is_valid());
    let original = first.image.as_ref().expect("native image").resource.clone();
    assert_eq!(Some(original.texture()), renderer.color_texture());

    packet.drawable_size = RenderDrawableSize::new(48, 32);
    renderer.render_checked(&packet).expect("smaller frame");
    let smaller = renderer.current_viewport_surface_state();
    assert!(Arc::ptr_eq(
        smaller.image.as_ref().expect("image"),
        first.image.as_ref().expect("image")
    ));
    assert_eq!(smaller.surface_id, first.surface_id);
    assert_eq!(smaller.region.capacity, first.region.capacity);
    assert_eq!(smaller.region.size, packet.drawable_size);
    assert_eq!(
        smaller.region.uv_max().x,
        48.0 / first.region.capacity.width as f32
    );

    // Allocation succeeds but submission cannot start while another host
    // owns the Device's frame. Keep the last successful image published.
    device.begin_frame().expect("outer frame");
    packet.drawable_size = RenderDrawableSize::new(
        first.region.capacity.width + 1,
        first.region.capacity.height + 1,
    );
    assert!(renderer.render_checked(&packet).is_err());
    device.end_frame();
    assert!(renderer.current_viewport_surface_state() == smaller);
    renderer.render_checked(&packet).expect("grown frame");
    let grown = renderer.current_viewport_surface_state();
    assert!(grown.is_valid() && grown.surface_id > smaller.surface_id);
    assert!(!Arc::ptr_eq(
        grown.image.as_ref().expect("grown image"),
        smaller.image.as_ref().expect("smaller image")
    ));

    device.wait_until_idle().expect("idle");
    assert!(
        !GridImage::readback(&device, original.texture(), smaller.region.size)
            .expect("held readback")
            .is_empty()
    );
}

/// A held surface outlives forty replacements and the renderer.
#[test]
fn held_surface_outlives_replacements_and_renderer() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, true).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let mut renderer = Some(NativeGridRenderer::new(&device, None).expect("grid renderer"));
    let mut packet = GridProbeScene::packet(RenderDrawableSize::new(32, 24), 0, None);
    renderer
        .as_ref()
        .expect("renderer")
        .render_checked(&packet)
        .expect("first frame");
    let retained = renderer
        .as_ref()
        .expect("renderer")
        .current_viewport_surface_state();
    let lease = retained.image.as_ref().map(Arc::downgrade);
    let expected = GridImage::readback(
        &device,
        retained.image.as_ref().expect("image").resource.texture(),
        packet.drawable_size,
    )
    .expect("readback");

    for frame in 1..=40 {
        packet.frame_index = frame;
        packet.drawable_size.width = 32 + frame as u32;
        renderer
            .as_ref()
            .expect("renderer")
            .render_checked(&packet)
            .expect("replacement frame");
    }
    drop(renderer.take());
    assert!(
        lease
            .as_ref()
            .is_some_and(|lease| lease.upgrade().is_some())
    );
    assert_eq!(
        GridImage::readback(
            &device,
            retained.image.as_ref().expect("image").resource.texture(),
            retained.region.size,
        )
        .expect("held readback"),
        expected
    );
    drop(retained);
    assert!(
        lease
            .as_ref()
            .is_some_and(|lease| lease.upgrade().is_none())
    );

    device.wait_until_idle().expect("idle");
}

/// Invalid sampling regions are rejected.
#[test]
fn invalid_sampling_regions_are_rejected() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, true).expect("device") else {
        return;
    };
    let device = Arc::new(device);
    let resource = Arc::new(
        TextureResource::new(
            device.clone(),
            TextureDescriptor::new(
                8,
                8,
                TextureFormat::Bgra8Unorm,
                TextureUsage::SAMPLED | TextureUsage::COLOR_TARGET,
            ),
        )
        .expect("texture"),
    );
    let mut state = ViewportSurfaceState::with_region(
        1,
        Some(Arc::new(ViewportImage::new(resource, Vec::new()))),
        ViewportSamplingRegion::new(RenderDrawableSize::new(4, 6), RenderDrawableSize::new(8, 8)),
    );
    assert!(state.is_valid());
    state.region.size.width = 9;
    assert!(!state.is_valid());
    assert_eq!(state.region.uv_max(), Float2::ZERO);
    state.region.size.width = 4;
    state.region.capacity.width = 16;
    assert!(!state.is_valid());

    device.wait_until_idle().expect("idle");
}
