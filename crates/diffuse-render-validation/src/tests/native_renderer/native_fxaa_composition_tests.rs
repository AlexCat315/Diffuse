//! Ported from `Engine/Tests/NativeRendererTests/NativeFXAACompositionTests.swift`.
//!
//! Capability switches must compose into a valid pipeline in any combination.
//! FXAA is an LDR antialias and must work for a non-PBR scene too: the scene
//! renders into the LDR target and FXAA resolves it to the final color.

use std::sync::Arc;

use diffuse_assets::asset_pipeline::BuiltinMesh;
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_math::simd::simd_compat::{Float3, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::{RenderDrawableSize, RenderSettings};
use diffuse_scene::rendering::render_scene::{RenderInstance, RenderMaterial};

use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::reference::grid_image::GridImage;
use crate::tests::native_renderer::support::device;

/// FXAA without PBR renders and changes pixels.
#[test]
fn fxaa_without_pbr_renders_and_changes_pixels() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let cube = BuiltinMesh::cube(Some(Float3::splat(1.0)));
    AssetRegistry::shared().register_for_testing(cube, 88);
    let Some(device) = device::make_for(device::validation_api(), false).expect("device") else {
        AssetRegistry::shared().unregister_testing_mesh(88);
        return;
    };
    let device = Arc::new(device);
    let mut renderer = NativeRenderer::new(
        &device,
        None,
        AssetRegistry::shared(),
        None,
        &RenderSettings::new(),
        &[],
    )
    .expect("renderer");
    let size = RenderDrawableSize::new(256, 192);

    let packet = |fxaa: bool, frame: i64| {
        let mut packet = MeshProbeScene::packet(size, frame);
        packet.render_settings.shading.pbr = false;
        packet.render_settings.shading.depth_prepass = false;
        packet.render_settings.post_processing.fxaa = fxaa;
        packet.scene.instances = vec![RenderInstance::from_mesh_index(
            88,
            MATRIX_IDENTITY_FLOAT4X4,
            Float3::splat(1.0),
            RenderMaterial::fallback(),
            None,
        )];
        packet
    };

    renderer
        .render_checked(&packet(false, 0))
        .expect("frame without FXAA");
    let without_fxaa = GridImage::readback(&device, renderer.color_texture().expect("color"), size)
        .expect("readback");

    // Two frames so the FXAA path is exercised on a warm frame slot too.
    renderer
        .render_checked(&packet(true, 1))
        .expect("FXAA frame 1");
    renderer
        .render_checked(&packet(true, 2))
        .expect("FXAA frame 2");
    let with_fxaa = GridImage::readback(&device, renderer.color_texture().expect("color"), size)
        .expect("readback");

    let delta = GridImage::difference(&without_fxaa, &with_fxaa).expect("difference");
    assert!(
        delta.pixels_over_three > 0,
        "FXAA must change actual pixels"
    );

    device.wait_until_idle().expect("idle");
    AssetRegistry::shared().unregister_testing_mesh(88);
}
