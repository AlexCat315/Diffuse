//! Ported from `Editor/Tests/EditorCoreTests/Rendering/NativeInGameUIIntegrationTests.swift`.

use std::sync::Arc;

use cove_graphics::rhi::{Device, DeviceConfig, RhiResult};
use cove_ui_compose::primitives::text::Text;
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_kernel::in_game_canvas::{InGameCanvas, InGameUIColor};
use diffuse_render::RenderDrawableSize;
use diffuse_render::RenderPacket;
use diffuse_render::RenderSettings;
use diffuse_render::core::frame::render_frame_plan::RenderPassKind;
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::surface::in_game_ui_providing::{
    InGameUIProviding, InGameUIRecordingOutcome, InGameUIRecordingOutcomeError,
    NativeInGameUITarget,
};
use diffuse_render_validation::GridImage;
use diffuse_render_validation::PostProbeScene;
use diffuse_render_validation::probes::mesh_probe_scene::MeshProbeScene;
use diffuse_scene::scene_runtime::SceneRuntimeSnapshot;

use crate::rendering::hud::in_game_ui_host::InGameUIHost;
use crate::tests::editor_core::rendering::native_viewport_test_context::NativeViewportTestContext;

fn gpu_resources_available() -> bool {
    std::env::var_os("COVE_RESOURCE_PATH").is_some()
}

/// `InGameUIHost` is constructed once and shared with the renderer, mirroring
/// Swift's class reference semantics.
#[derive(Clone)]
struct SharedHost(Arc<InGameUIHost>);

impl InGameUIProviding for SharedHost {
    fn record_in_game_ui(
        &self,
        packet: &RenderPacket,
        snapshot: &SceneRuntimeSnapshot,
        target: NativeInGameUITarget,
    ) -> Result<InGameUIRecordingOutcome, InGameUIRecordingOutcomeError> {
        self.0.record_in_game_ui(packet, snapshot, target)
    }
}

fn scene_with_hud(
    device: &Arc<Device>,
    provider: Option<Box<dyn InGameUIProviding>>,
) -> RhiResult<NativeRenderer> {
    NativeRenderer::new(
        device,
        None,
        AssetRegistry::shared(),
        provider,
        &RenderSettings::default(),
        &[],
    )
}

/// Production scene HUD matches the reference renderer across scale and
/// target capacity.
#[test]
fn production_scene_hud_parity_across_scale_and_capacity() {
    if !gpu_resources_available() {
        return;
    }
    let mut context = NativeViewportTestContext::new().expect("test context");
    let hud = context.hud.clone();
    let mut scene =
        scene_with_hud(&context.device, Some(Box::new(hud.clone()))).expect("scene renderer");
    let native_hud = Arc::new(InGameUIHost::new(context.device.clone()).expect("native HUD"));
    let reference_hud =
        Arc::new(InGameUIHost::new(context.reference.device.clone()).expect("reference HUD"));
    native_hud.set_root_view(Text::new("HUD 中🙂"));
    reference_hud.set_root_view(Text::new("HUD 中🙂"));

    let logical_sizes = [
        RenderDrawableSize::new(192, 128),
        RenderDrawableSize::new(80, 64),
        RenderDrawableSize::new(160, 96),
    ];
    let scales = [1.0f32, 1.5, 2.0];
    let mut evidence = Vec::new();

    for post in [false, true] {
        for (index, scale) in scales.into_iter().enumerate() {
            let logical = logical_sizes[index];
            let size = RenderDrawableSize::new(
                (logical.width as f32 * scale) as u32,
                (logical.height as f32 * scale) as u32,
            );
            let mut packet = if post {
                PostProbeScene::packet(size, 0)
            } else {
                MeshProbeScene::packet(size, 0)
            };
            packet.frame_index = (if post { 3 } else { 0 }) + index as i64;
            packet.render_settings.post_processing.taa = false;
            packet.render_settings.post_processing.ssr = false;

            hud.set_provider(None);
            scene.render_checked(&packet).expect("base frame");
            let color_texture = scene.color_texture().expect("scene color texture");
            let base = GridImage::readback(&context.device, color_texture, size).expect("base");

            if index != 0 {
                packet
                    .in_game_canvas
                    .rect_rounded(4.0, 32.0, 70.0, 28.0, InGameUIColor::BLUE, 4.0);
                packet.in_game_canvas.label_styled(
                    "Score 8 🙂",
                    6.0,
                    35.0,
                    14.0,
                    InGameUIColor::WHITE,
                );
                packet
                    .in_game_canvas
                    .progress_bar(6.0, 55.0, 64.0, 4.0, 0.65);
            }
            // Two unconsumed ticks exercise atlas accumulation when the
            // render thread skips a producer frame, including scale changes.
            for _ in 0..2 {
                native_hud.tick(
                    logical.width,
                    logical.height,
                    scale,
                    packet.in_game_canvas.clone(),
                );
                reference_hud.tick(
                    logical.width,
                    logical.height,
                    scale,
                    packet.in_game_canvas.clone(),
                );
            }

            hud.set_provider(Some(Box::new(SharedHost(native_hud.clone()))));
            scene.render_checked(&packet).expect("native HUD frame");
            let native =
                GridImage::readback(&context.device, color_texture, size).expect("native readback");
            let stats = scene.current_frame_stats();
            assert_eq!(stats.active_passes.last(), Some(&RenderPassKind::InGameUI));
            assert!(
                stats
                    .pass_draw_call_counts
                    .get(&RenderPassKind::InGameUI)
                    .copied()
                    .unwrap_or(0)
                    > 0
            );

            if index != 0 {
                let mut visible_label_pixels = 0;
                for y in (35.0 * scale) as usize..(52.0 * scale) as usize {
                    for x in
                        (6.0 * scale) as usize..((70.0 * scale) as usize).min(size.width as usize)
                    {
                        let pixel = (y * size.width as usize + x) * 4;
                        if native[pixel] > 180 && native[pixel + 1] > 180 && native[pixel + 2] > 180
                        {
                            visible_label_pixels += 1;
                        }
                    }
                }
                assert!(
                    visible_label_pixels > 20,
                    "unchanged script label must remain visible after atlas/scale replacement"
                );
            }

            let hud_delta = GridImage::difference(&native, &base).expect("base delta");
            assert!(
                hud_delta.pixels_over_three > 100,
                "declarative HUD must render even with an empty script canvas"
            );

            hud.set_provider(Some(Box::new(SharedHost(reference_hud.clone()))));
            let reference_stats = context.reference.render(&packet).expect("reference frame");
            assert_eq!(
                reference_stats.active_passes.last(),
                Some(&RenderPassKind::InGameUI)
            );
            let expected = context.reference.readback().expect("reference readback");
            let delta = GridImage::difference(&native, &expected).expect("parity delta");
            assert!(
                delta.mean_absolute_channel_error < 0.5,
                "{post}/{scale}: {delta:?}"
            );
            assert!(
                (delta.pixels_over_three as f64) / (delta.pixel_count as f64) < 0.01,
                "{post}/{scale}: {delta:?}"
            );
            evidence.push(serde_json::json!({
                "post": post,
                "scale": scale,
                "width": size.width,
                "height": size.height,
                "mean": delta.mean_absolute_channel_error,
                "maximum": delta.maximum_channel_error,
                "pixelsOverThree": delta.pixels_over_three,
                "pixelCount": delta.pixel_count,
                "nativeHUDDrawCalls": stats.pass_draw_call_counts.get(&RenderPassKind::InGameUI).copied().unwrap_or(0),
                "repeatHUDDrawCalls": reference_stats.pass_draw_call_counts.get(&RenderPassKind::InGameUI).copied().unwrap_or(0),
            }));
            if post && index == 2 {
                let temp = std::env::temp_dir();
                GridImage::write_ppm(&native, size, &temp.join("cove-native-hud.ppm"))
                    .expect("native HUD image");
                GridImage::write_ppm(&expected, size, &temp.join("cove-repeat-hud.ppm"))
                    .expect("reference HUD image");
            }
        }
    }

    let report = serde_json::json!({
        "backend": std::env::var("COVE_RHI_BACKEND").unwrap_or_default(),
        "samples": evidence,
    });
    std::fs::write(
        std::env::temp_dir().join("cove-native-hud-parity.json"),
        serde_json::to_vec_pretty(&report).expect("evidence JSON"),
    )
    .expect("evidence file");
}

/// The HUD refreshes outside the opaque cache and an empty snapshot clears it.
#[test]
fn hud_refreshes_outside_opaque_cache_and_empty_snapshot_clears_it() {
    if !gpu_resources_available() {
        return;
    }
    let device = Arc::new(Device::make(DeviceConfig::default()).expect("device"));
    let hud = super::hud_router::HUDRouter::new();
    let mut scene = scene_with_hud(&device, Some(Box::new(hud.clone()))).expect("scene renderer");
    let host = Arc::new(InGameUIHost::new(device.clone()).expect("HUD host"));
    hud.set_provider(Some(Box::new(SharedHost(host.clone()))));

    let size = RenderDrawableSize::new(192, 128);
    let mut packet = PostProbeScene::packet(size, 0);
    packet.render_settings.post_processing.taa = false;
    packet.render_settings.post_processing.ssr = false;
    packet
        .in_game_canvas
        .rect(0.0, 0.0, 32.0, 24.0, InGameUIColor::RED);
    host.tick(192, 128, 1.0, packet.in_game_canvas.clone());
    for frame in 0..3 {
        packet.frame_index = frame;
        scene.render_checked(&packet).expect("red frame");
    }
    assert!(scene.last_frame_used_opaque_cache());
    let color_texture = scene.color_texture().expect("color texture");
    let red = GridImage::readback(&device, color_texture, size).expect("red readback");
    assert_eq!(&red[0..4], [0, 0, 255, 255]);

    packet.frame_index += 1;
    packet.in_game_canvas = InGameCanvas::new();
    packet
        .in_game_canvas
        .rect(0.0, 0.0, 32.0, 24.0, InGameUIColor::BLUE);
    host.tick(192, 128, 1.0, packet.in_game_canvas.clone());
    scene.render_checked(&packet).expect("blue frame");
    assert!(scene.last_frame_used_opaque_cache());
    let blue = GridImage::readback(&device, color_texture, size).expect("blue readback");
    assert_eq!(&blue[0..4], [255, 102, 0, 255]);

    packet.frame_index += 1;
    packet.in_game_canvas = InGameCanvas::new();
    host.tick_default(192, 128);
    scene.render_checked(&packet).expect("empty frame");
    assert!(scene.last_frame_used_opaque_cache());
    assert!(
        !scene
            .current_frame_stats()
            .active_passes
            .contains(&RenderPassKind::InGameUI)
    );
    let cleared = GridImage::readback(&device, color_texture, size).expect("cleared readback");

    hud.set_provider(None);
    packet.frame_index += 1;
    scene.render_checked(&packet).expect("cache frame");
    assert_eq!(
        cleared,
        GridImage::readback(&device, color_texture, size).expect("cached readback")
    );
}
