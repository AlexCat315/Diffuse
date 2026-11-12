//! Ported from `Engine/Tests/NativeRendererTests/NativePBRTests.swift`.

use std::sync::Arc;

use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_kernel::in_game_canvas::InGameUIColor;
use diffuse_math::simd::simd_compat::{Float3, Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::native::targets::native_packet_validation::NativePacketValidation;
use diffuse_render::{RenderDrawableSize, RenderSettings};
use diffuse_scene::rendering::render_scene::{
    RenderCameraProjection, RenderInstance, RenderMaterial,
};

use crate::probes::mesh_probe_scene::MeshProbeScene;
use crate::probes::pbr_probe_scene::PBRProbeScene;
use crate::reference::grid_image::GridImage;
use crate::reference::scene_capture::SceneCapture;
use crate::tests::native_renderer::support::device;

/// Scene validation accepts a canvas and post effects together.
#[test]
fn scene_validation_accepts_canvas_and_post_effects() {
    let mut packet = PBRProbeScene::packet(RenderDrawableSize::new(64, 64), 0);
    NativePacketValidation::validate(&packet).expect("valid packet");
    packet
        .in_game_canvas
        .rect(0.0, 0.0, 10.0, 10.0, InGameUIColor::WHITE);
    NativePacketValidation::validate(&packet).expect("canvas packet");
    packet.in_game_canvas.commands.clear();
    packet.render_settings.post_processing.taa = true;
    NativePacketValidation::validate(&packet).expect("TAA packet");
    packet.render_settings.post_processing.taa = false;
    NativePacketValidation::validate(&packet).expect("final packet");
}

/// PBR + shadows + HDR match the independent reference capture frame by frame.
#[test]
fn pbr_shadow_hdr_parity() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = crate::tests::native_renderer::support::lock_serial();
    let api = device::validation_api();
    let Some(device) = device::make_for(api, false).expect("device") else {
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
    let mut reference = SceneCapture::new(true, Some(api), None).expect("reference capture");

    let mut asset = MeshProbeScene::imported_fixture().expect("fixture");
    for material in &mut asset.materials {
        material.normal_texture_index = Some(0);
        material.metallic_roughness_texture_index = Some(0);
    }
    AssetRegistry::shared().register_for_testing(asset, 2);

    let mut packet = PBRProbeScene::packet(RenderDrawableSize::new(256, 192), 0);
    let mut transform = MATRIX_IDENTITY_FLOAT4X4;
    transform.columns[3] = Float4::new(0.0, 1.4, 3.0, 1.0);
    packet.scene.instances.push(RenderInstance::from_mesh_index(
        2,
        transform,
        Float3::splat(1.0),
        RenderMaterial::fallback(),
        None,
    ));

    let directory = std::env::temp_dir().join(format!("cove-native-pbr-{api:?}"));
    std::fs::create_dir_all(&directory).expect("output directory");
    let mut snapshots: Vec<Vec<u8>> = Vec::new();
    for frame in 0..8 {
        packet.frame_index = frame;
        match frame {
            0 => packet.render_settings.shadows.enabled = false,
            1 => {
                packet.render_settings.shadows.enabled = true;
                packet.render_settings.shadows.directional_cascade_count = 1;
            }
            2 => packet.render_settings.shadows.directional_cascade_count = 3,
            3 => {
                packet.scene.environment.exposure = 0.45;
                packet.render_settings.shading.debug_view_mode =
                    diffuse_render::DebugViewMode::WorldNormal;
            }
            4 => {
                packet.render_settings.shading.debug_view_mode =
                    diffuse_render::DebugViewMode::Shaded;
                packet.scene.camera.projection = RenderCameraProjection::Orthographic;
                packet.scene.camera.orthographic_height = 14.0;
            }
            5 => {
                packet.scene.camera.eye = Float3::new(-8.0, 6.0, 10.0);
                packet.scene.lights.clear();
                packet.render_settings.shadows.enabled = false;
            }
            6 => {
                packet.drawable_size = RenderDrawableSize::new(192, 128);
                packet.scene.environment.ambient_intensity = 0.0;
                packet.scene.environment.exposure = 2.5;
            }
            _ => {
                packet.render_settings.shading.pbr = false;
                packet.render_settings.shading.depth_prepass = true;
                packet.render_settings.shading.debug_view_mode =
                    diffuse_render::DebugViewMode::Unlit;
            }
        }
        renderer.render_checked(&packet).expect("native frame");
        reference.render(&packet).expect("reference frame");
        let native = GridImage::readback(
            &device,
            renderer.color_texture().expect("color texture"),
            packet.drawable_size,
        )
        .expect("native readback");
        let expected = reference.readback().expect("reference readback");
        let delta = GridImage::difference(&native, &expected).expect("difference");
        assert!(
            delta.mean_absolute_channel_error < 0.5,
            "{api:?} frame {frame}: {delta:?}"
        );
        assert!(
            delta.pixels_over_three < 1.max(delta.pixel_count / 100),
            "{api:?} frame {frame}: {delta:?}"
        );
        if frame == 1 {
            assert_eq!(renderer.current_frame_stats().shadow_tile_count, 2);
            assert_eq!(renderer.current_frame_stats().shadowed_light_count, 2);
        }
        if frame == 2 {
            assert_eq!(renderer.current_frame_stats().shadow_tile_count, 4);
            assert_eq!(renderer.current_frame_stats().shadow_cascade_count, 3);
        }
        if frame < 7 {
            assert!(
                renderer
                    .current_frame_stats()
                    .active_passes
                    .contains(&diffuse_render::RenderPassKind::Tonemap)
            );
        }
        GridImage::write_ppm(
            &native,
            packet.drawable_size,
            &directory.join(format!("frame-{frame}.ppm")),
        )
        .expect("write native frame");
        GridImage::write_ppm(
            &expected,
            packet.drawable_size,
            &directory.join(format!("repeat-{frame}.ppm")),
        )
        .expect("write reference frame");
        snapshots.push(native);
    }

    // Shadow enablement must change actual receiver pixels, and clearing all
    // light/ambient inputs must leave no stale shaded objects in the frame.
    assert!(
        GridImage::difference(&snapshots[0], &snapshots[1])
            .expect("difference")
            .pixels_over_three
            > 20
    );
    assert_eq!(renderer.current_frame_stats().shadow_tile_count, 0);

    device.wait_until_idle().expect("idle");
    AssetRegistry::shared().unregister_testing_mesh(2);
}
