//! Ported from
//! `Engine/Tests/EngineCoreTests/RenderBackend/Core/RenderBackendGPUSmokeTests.swift`.
//!
//! The Swift suite runs serialized and is gated on
//! `COVE_RUN_GPU_SMOKE_TESTS=1`; both renderers here are process-wide GPU
//! state, so the tests keep that gate and run the parameterised scenes in a
//! loop.

use std::sync::Arc;

use cove_graphics::rhi::{Device, DeviceConfig};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::native::passes::native_grid_renderer::NativeGridRenderer;
use diffuse_render::{RenderDrawableSize, RenderPacket, RenderPassKind, RenderSettings};
use diffuse_render_validation::{
    AnimatedProbeScene, GridImage, GridProbeScene, MeshProbeScene, PBRProbeScene,
    ParticleProbeScene, ParticleSimulationProbeScene, PostProbeScene, StylizedProbeScene,
};

const SCENES: [&str; 7] = [
    "mesh",
    "pbr",
    "post",
    "stylized",
    "particles",
    "simulation",
    "animated",
];

fn gpu_smoke_tests_enabled() -> bool {
    std::env::var("COVE_RUN_GPU_SMOKE_TESTS").as_deref() == Ok("1")
}

fn scene_packet(scene: &str, size: RenderDrawableSize) -> RenderPacket {
    match scene {
        "mesh" => MeshProbeScene::packet(size, 0),
        "pbr" => PBRProbeScene::packet(size, 0),
        "post" => PostProbeScene::packet(size, 0),
        "stylized" => StylizedProbeScene::packet(size, 0),
        "particles" => ParticleProbeScene::packet(size, 0),
        "simulation" => ParticleSimulationProbeScene::packet(size, 0),
        _ => AnimatedProbeScene::packet(size, 0),
    }
}

/// Counts pixels whose RGB differs from the first pixel's RGB.
fn covered_pixels(pixels: &[u8]) -> usize {
    pixels
        .as_chunks::<4>()
        .0
        .iter()
        .filter(|pixel| pixel[0..3] != pixels[0..3])
        .count()
}

/// All production scene passes render readable, nonuniform pixels.
#[test]
fn production_scenes_render_readable_pixels() {
    if !gpu_smoke_tests_enabled() {
        return;
    }

    let size = RenderDrawableSize::new(192, 128);

    for scene in SCENES {
        let device = Arc::new(Device::make(DeviceConfig::default()).expect("device"));
        let mut renderer = NativeRenderer::new(
            &device,
            None,
            AssetRegistry::shared(),
            None,
            &RenderSettings::new(),
            &[],
        )
        .expect("renderer");

        if scene == "animated" {
            AssetRegistry::shared().register_for_testing(AnimatedProbeScene::skinned_fixture(), 2);
        }

        let mut packet = scene_packet(scene, size);
        renderer
            .render_checked(&packet)
            .unwrap_or_else(|e| panic!("{scene} first frame: {e}"));
        if scene == "post" {
            // SSR refines a stable opaque scene; the initial frame intentionally
            // omits it while establishing temporal history.
            assert!(
                !renderer
                    .current_frame_stats()
                    .active_passes
                    .contains(&RenderPassKind::Ssr)
            );
            packet = PostProbeScene::packet(size, 1);
            renderer.render_checked(&packet).expect("second frame");
        }
        let stats = renderer.current_frame_stats();
        assert_eq!(stats.frame_index, packet.frame_index, "{scene}");
        assert!(stats.draw_call_count > 0, "{scene}");
        assert!(renderer.current_viewport_surface_state().is_valid());

        let texture = renderer.color_texture().expect("color texture");
        let pixels = GridImage::readback(&device, texture, size).expect("readback");
        if let Some(output) = std::env::var_os("COVE_GPU_TEST_OUTPUT_DIR") {
            let output = std::path::PathBuf::from(output);
            std::fs::create_dir_all(&output).expect("output directory");
            GridImage::write_ppm(&pixels, size, &output.join(format!("{scene}.ppm")))
                .expect("write ppm");
        }
        assert_eq!(
            pixels.len(),
            size.width as usize * size.height as usize * 4,
            "{scene}"
        );
        // Flat unlit meshes legitimately use only a few colors. Require visible
        // coverage in RGB rather than an arbitrary number of blue-channel shades.
        assert!(covered_pixels(&pixels) > 32, "{scene}");

        if scene == "post" {
            for kind in [
                RenderPassKind::Ssao,
                RenderPassKind::Ssr,
                RenderPassKind::Taa,
                RenderPassKind::Bloom,
                RenderPassKind::Fxaa,
                RenderPassKind::Tonemap,
            ] {
                assert!(stats.active_passes.contains(&kind), "{scene} {kind:?}");
            }
        }
        if scene == "simulation" {
            assert!(stats.gpu_particle_simulation_particle_count > 0);
            assert!(stats.gpu_particle_sort_pass_count > 0);
            assert!(stats.gpu_particle_render_instance_count > 0);
        }

        if scene == "animated" {
            AssetRegistry::shared().unregister_testing_mesh(2);
        }
    }
}

/// Grid coverage survives resize and empty scenes.
#[test]
fn editor_grid_coverage_survives_resize() {
    if !gpu_smoke_tests_enabled() {
        return;
    }

    let device = Arc::new(Device::make(DeviceConfig::default()).expect("device"));
    let renderer = NativeGridRenderer::new(&device, None).expect("grid renderer");

    for size in [
        RenderDrawableSize::new(192, 128),
        RenderDrawableSize::new(96, 160),
    ] {
        let mut packet = GridProbeScene::packet(size, 0, None);
        renderer.render_checked(&packet).expect("grid frame");
        let pixels = GridImage::readback(
            &device,
            renderer.color_texture().expect("color texture"),
            size,
        )
        .expect("readback");

        packet.render_settings.viewport.grid_enabled = false;
        renderer.render_checked(&packet).expect("cleared frame");
        let clear = GridImage::readback(
            &device,
            renderer.color_texture().expect("color texture"),
            size,
        )
        .expect("readback");

        let difference = GridImage::difference(&pixels, &clear).expect("difference");
        assert!(difference.pixels_over_three > 300);
        assert_eq!(renderer.current_frame_stats().draw_call_count, 0);
    }
}
