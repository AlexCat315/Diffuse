//! Ported from `Engine/Tests/NativeRendererTests/NativePostTests.swift`.

use std::sync::Arc;

use diffuse_math::simd::simd_compat::{Float4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_render::core::frame::render_packet::RenderPacket;
use diffuse_render::core::lighting::post_effect_uniforms::PostEffectUniforms;
use diffuse_render::core::mesh::opaque_scene_fingerprint::OpaqueSceneFingerprint;
use diffuse_render::core::render_temporal_state::{
    RenderFrameResourceVersion, RenderTemporalState,
};
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::{RenderDrawableSize, RenderPassKind, RenderSettings};
use diffuse_scene::rendering::render_scene::{RenderInstance, RenderMaterial};

use crate::probes::pbr_probe_scene::PBRProbeScene;
use crate::probes::post_probe_scene::PostProbeScene;
use crate::reference::grid_image::GridImage;
use crate::reference::scene_capture::SceneCapture;
use crate::tests::native_renderer::support::{device, lock_serial};

fn clear_effects(packet: &mut RenderPacket) {
    packet.render_settings.post_processing.ssao = false;
    packet.render_settings.post_processing.ssr = false;
    packet.render_settings.post_processing.taa = false;
    packet.render_settings.post_processing.bloom = false;
    packet.render_settings.post_processing.fxaa = false;
}

fn make_renderer(
    api: cove_graphics::rhi::GraphicsApi,
) -> Option<(Arc<cove_graphics::rhi::Device>, NativeRenderer)> {
    let device = device::make_for(api, false).expect("device")?;
    let device = Arc::new(device);
    let renderer = NativeRenderer::new(
        &device,
        None,
        diffuse_assets::asset_registry::AssetRegistry::shared(),
        None,
        &RenderSettings::new(),
        &[],
    )
    .expect("renderer");
    Some((device, renderer))
}

fn compare(
    device: &Arc<cove_graphics::rhi::Device>,
    renderer: &mut NativeRenderer,
    reference: &mut SceneCapture,
    packet: &RenderPacket,
    label: &str,
    directory: &std::path::Path,
) -> Vec<u8> {
    renderer.render_checked(packet).expect("native frame");
    reference.render(packet).expect("reference frame");
    let native = GridImage::readback(
        device,
        renderer.color_texture().expect("native color"),
        packet.drawable_size,
    )
    .expect("native readback");
    let expected = reference.readback().expect("reference readback");
    let delta = GridImage::difference(&native, &expected).expect("difference");
    assert!(
        delta.mean_absolute_channel_error < 0.5,
        "{label}: {delta:?}"
    );
    assert!(
        delta.pixels_over_three < delta.pixel_count / 100,
        "{label}: {delta:?}"
    );
    GridImage::write_ppm(
        &native,
        packet.drawable_size,
        &directory.join(format!("{label}.ppm")),
    )
    .expect("native ppm");
    GridImage::write_ppm(
        &expected,
        packet.drawable_size,
        &directory.join(format!("repeat-{label}.ppm")),
    )
    .expect("reference ppm");
    native
}

/// The fingerprint preserves duplicates and ignores extraction order.
#[test]
fn fingerprint_preserves_duplicates_and_ignores_order() {
    let mut packet = PBRProbeScene::packet(RenderDrawableSize::new(64, 64), 0);
    let a = packet.scene.instances[0].clone();
    let b = packet.scene.instances[1].clone();
    packet.scene.instances = vec![a.clone(), a.clone()];
    let first = OpaqueSceneFingerprint::make(&packet, 1);
    packet.scene.instances = vec![b.clone(), b.clone()];
    assert_ne!(first, OpaqueSceneFingerprint::make(&packet, 1));
    packet.scene.instances = vec![a, b];
    let mixed = OpaqueSceneFingerprint::make(&packet, 1);
    packet.scene.instances.reverse();
    assert_eq!(mixed, OpaqueSceneFingerprint::make(&packet, 1));
}

/// A failed resize invalidates history on the next successful submission.
#[test]
fn frame_history_invalidates_resource_epoch_after_failed_resize() {
    let mut packet = PostProbeScene::packet(RenderDrawableSize::new(64, 64), 0);
    let mut state = RenderTemporalState::new();
    state.prepare(
        &packet,
        RenderFrameResourceVersion::new(Some(1), 1, packet.drawable_size),
        true,
    );
    state.history_valid = true;
    let submitted = state.clone();
    let mut abandoned = state.clone();
    packet.drawable_size = RenderDrawableSize::new(128, 64);
    abandoned.prepare(
        &packet,
        RenderFrameResourceVersion::new(Some(1), 2, packet.drawable_size),
        true,
    );
    state = submitted;
    state.prepare(
        &packet,
        RenderFrameResourceVersion::new(Some(1), 2, packet.drawable_size),
        true,
    );
    assert!(!state.history_valid);
    assert!(state.moving());
}

/// A used-region resize invalidates history and snapshot without reallocation.
#[test]
fn used_region_resize_invalidates_history() {
    let mut packet = PostProbeScene::packet(RenderDrawableSize::new(128, 96), 0);
    let mut state = RenderTemporalState::new();
    state.prepare(
        &packet,
        RenderFrameResourceVersion::new(Some(1), 1, packet.drawable_size),
        true,
    );
    state.history_valid = true;
    state.snapshot_valid = true;
    packet.drawable_size = RenderDrawableSize::new(96, 64);
    state.prepare(
        &packet,
        RenderFrameResourceVersion::new(Some(1), 1, packet.drawable_size),
        true,
    );
    assert!(!state.history_valid);
    assert!(!state.snapshot_valid);
    assert!(!state.cache_hit());
    let frame = PostEffectUniforms::frame(packet.drawable_size, RenderDrawableSize::new(256, 256));
    assert_eq!(
        frame.uv_scale_max,
        Float4::new(96.0 / 256.0, 64.0 / 256.0, 95.5 / 256.0, 63.5 / 256.0)
    );
}

/// Post history survives resizes and matches the reference capture.
#[test]
fn post_history_resize_and_cache_parity() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some((device, mut renderer)) = make_renderer(api) else {
        return;
    };
    let mut reference = SceneCapture::new(true, Some(api), None).expect("reference");
    let mut packet = PostProbeScene::packet(RenderDrawableSize::new(256, 192), 0);
    clear_effects(&mut packet);
    let directory = std::env::temp_dir().join("cove-native-post");
    std::fs::create_dir_all(&directory).expect("output directory");
    let mut previous_color = None;
    for frame in 0..24 {
        packet.frame_index = frame;
        match frame {
            1 => packet.render_settings.post_processing.ssao = true,
            3 => packet.render_settings.post_processing.ssr = true,
            5 => packet.render_settings.post_processing.taa = true,
            6 => {
                packet.render_settings.post_processing.bloom = true;
                packet.render_settings.post_processing.fxaa = true;
                packet.scene.camera.eye.x += 0.2;
            }
            8 => packet.render_settings.viewport.grid_enabled = false,
            9 => packet.drawable_size = RenderDrawableSize::new(192, 128),
            10 => packet.drawable_size = RenderDrawableSize::new(320, 200),
            11 => packet.render_settings.post_processing.taa = false,
            12 => packet.render_settings.post_processing.taa = true,
            20 => {
                let last = packet.scene.instances.len() - 1;
                packet.scene.instances[last].material.base_color_factor =
                    Float4::new(0.75, 0.25, 0.15, 0.35);
            }
            21 => {
                let mut invalid = packet.clone();
                invalid.drawable_size = RenderDrawableSize::new(640, 384);
                invalid
                    .scene
                    .instances
                    .push(RenderInstance::from_mesh_index(
                        999,
                        MATRIX_IDENTITY_FLOAT4X4,
                        diffuse_math::simd::simd_compat::Float3::splat(1.0),
                        RenderMaterial::fallback(),
                        None,
                    ));
                assert!(renderer.render_checked(&invalid).is_err());
                // Recreated targets require a fresh history after recovery.
                reference = SceneCapture::new(true, Some(api), None).expect("reference");
            }
            22 => clear_effects(&mut packet),
            23 => {
                packet.render_settings.post_processing.taa = true;
                packet.render_settings.post_processing.ssao = true;
                packet.render_settings.post_processing.ssr = true;
                packet.render_settings.post_processing.bloom = true;
                packet.render_settings.post_processing.fxaa = true;
                packet.scene.camera.projection =
                    diffuse_scene::rendering::render_scene::RenderCameraProjection::Orthographic;
                packet.scene.camera.orthographic_height = 14.0;
            }
            _ => {}
        }
        compare(
            &device,
            &mut renderer,
            &mut reference,
            &packet,
            &format!("frame-{frame}"),
            &directory,
        );
        if frame == 9 {
            assert_eq!(
                renderer.color_texture(),
                previous_color,
                "shrinking viewport must reuse allocated targets"
            );
        }
        if frame == 10 {
            assert_ne!(
                renderer.color_texture(),
                previous_color,
                "capacity grows for larger viewport"
            );
        }
        previous_color = renderer.color_texture();
        assert_eq!(
            renderer.last_frame_used_opaque_cache(),
            reference.renderer.last_frame_used_opaque_cache(),
            "cache frame {frame}"
        );
        let stats = renderer.current_frame_stats();
        if frame == 3 {
            assert!(
                !stats
                    .pass_draw_call_counts
                    .contains_key(&RenderPassKind::Ssr)
            );
        }
        if frame == 4 {
            assert_eq!(
                stats
                    .pass_draw_call_counts
                    .get(&RenderPassKind::Ssr)
                    .copied(),
                Some(1)
            );
        }
        if frame == 19 {
            assert!(renderer.last_frame_used_opaque_cache());
            assert!(
                !renderer
                    .current_frame_stats()
                    .pass_draw_call_counts
                    .contains_key(&RenderPassKind::Taa)
            );
        }
    }

    device.wait_until_idle().expect("idle");
}

/// Stateless post effects change actual pixels against the baseline.
#[test]
fn stateless_post_effects_change_pixels() {
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let _serial = lock_serial();
    let api = device::validation_api();
    let Some((device, mut renderer)) = make_renderer(api) else {
        return;
    };
    let mut reference = SceneCapture::new(true, Some(api), None).expect("reference");
    let mut packet = PostProbeScene::packet(RenderDrawableSize::new(256, 192), 0);
    clear_effects(&mut packet);
    packet.render_settings.viewport.grid_enabled = false;
    let directory = std::env::temp_dir().join("cove-native-post");
    std::fs::create_dir_all(&directory).expect("output directory");
    let baseline = compare(
        &device,
        &mut renderer,
        &mut reference,
        &packet,
        "baseline",
        &directory,
    );

    for (index, kind) in [
        RenderPassKind::Ssao,
        RenderPassKind::Ssr,
        RenderPassKind::Bloom,
        RenderPassKind::Fxaa,
    ]
    .into_iter()
    .enumerate()
    {
        clear_effects(&mut packet);
        packet.frame_index = index as i64 * 2 + 1;
        match kind {
            RenderPassKind::Ssao => packet.render_settings.post_processing.ssao = true,
            RenderPassKind::Ssr => packet.render_settings.post_processing.ssr = true,
            RenderPassKind::Bloom => packet.render_settings.post_processing.bloom = true,
            RenderPassKind::Fxaa => packet.render_settings.post_processing.fxaa = true,
            _ => {}
        }
        compare(
            &device,
            &mut renderer,
            &mut reference,
            &packet,
            &format!("{kind:?}-moving"),
            &directory,
        );
        packet.frame_index += 1;
        let output = compare(
            &device,
            &mut renderer,
            &mut reference,
            &packet,
            &format!("{kind:?}-settled"),
            &directory,
        );
        assert!(
            GridImage::difference(&baseline, &output)
                .expect("difference")
                .pixels_over_three
                > 20,
            "{kind:?} must affect actual pixels"
        );
    }

    device.wait_until_idle().expect("idle");
}
