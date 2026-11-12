//! Ported from `Editor/Tests/EditorCoreTests/Rendering/NativeInGameUILifecycleTests.swift`.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use cove_graphics::rhi::{
    CommandBuffer, Device, DeviceConfig, QueueClass, RenderColorTarget, RhiError, RhiResult,
    TextureDescriptor, TextureFormat, TextureResource, TextureUsage,
};
use cove_ui_compose::scene_core::{
    Color, DrawList, DrawListAtlasDirty, DrawListSnapshot, GlyphAtlasFormat, GlyphAtlasInfo, Point,
    Rect, color_glyph_atlas_id,
};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_kernel::in_game_canvas::{InGameCanvas, InGameUIColor};
use diffuse_render::RenderDrawableSize;
use diffuse_render::RenderPacket;
use diffuse_render::RenderSettings;
use diffuse_render::core::frame::render_frame_plan::RenderPassKind;
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::surface::in_game_ui_providing::{
    InGameUIProviding, InGameUIRecording, InGameUIRecordingOutcome, InGameUIRecordingOutcomeError,
    NativeInGameUITarget,
};
use diffuse_render_validation::GridImage;
use diffuse_render_validation::probes::mesh_probe_scene::MeshProbeScene;
use diffuse_scene::scene_runtime::SceneRuntimeSnapshot;

use super::hud_router::HUDRouter;
use crate::rendering::hud::renderer::NativeInGameUIRenderer;
use crate::rendering::hud::snapshots::InGameDrawListSource;
use crate::tests::editor_core::rendering::native_viewport_test_context::NativeViewportTestContext;

fn gpu_resources_available() -> bool {
    std::env::var_os("COVE_RESOURCE_PATH").is_some()
}

fn scene_with_provider(
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

#[derive(Clone, Copy, PartialEq)]
enum Failure {
    None,
    Recording,
    Submission,
}

#[derive(Clone)]
struct HUDSubmissionProbe {
    hud: Arc<NativeInGameUIRenderer>,
    failure: Arc<Mutex<Failure>>,
    acknowledgements: Arc<AtomicUsize>,
}

impl HUDSubmissionProbe {
    fn new(hud: NativeInGameUIRenderer) -> Self {
        HUDSubmissionProbe {
            hud: Arc::new(hud),
            failure: Arc::new(Mutex::new(Failure::None)),
            acknowledgements: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn set_failure(&self, failure: Failure) {
        *self
            .failure
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = failure;
    }

    fn failure(&self) -> Failure {
        *self
            .failure
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn acknowledgements(&self) -> usize {
        self.acknowledgements.load(Ordering::Relaxed)
    }
}

impl InGameUIProviding for HUDSubmissionProbe {
    fn record_in_game_ui(
        &self,
        packet: &RenderPacket,
        snapshot: &SceneRuntimeSnapshot,
        mut target: NativeInGameUITarget,
    ) -> Result<InGameUIRecordingOutcome, InGameUIRecordingOutcomeError> {
        if self.failure() == Failure::Submission {
            let texture = target.color.texture;
            target.commands.copy_pass(|encoder| {
                encoder.copy_texture(texture, texture, i64::MAX, 1);
            });
        }
        let outcome = self.hud.record_in_game_ui(packet, snapshot, target)?;
        if self.failure() == Failure::Recording {
            return Err(InGameUIRecordingOutcomeError {
                commands: outcome.commands,
                error: RhiError::invalid_argument("injected HUD recording failure"),
            });
        }
        let Some(recorded) = outcome.recording else {
            return Ok(InGameUIRecordingOutcome::new(outcome.commands, None));
        };
        let acknowledgements = self.acknowledgements.clone();
        let draw_call_count = recorded.draw_call_count;
        let wrapped = InGameUIRecording::new(draw_call_count, move || {
            acknowledgements.fetch_add(1, Ordering::Relaxed);
            let mut recorded = recorded;
            recorded.did_submit();
        });
        Ok(InGameUIRecordingOutcome::new(
            outcome.commands,
            Some(wrapped),
        ))
    }
}

fn snapshot(alpha: u8) -> DrawListSnapshot {
    let mut list = DrawList::default();
    let glyph = GlyphAtlasInfo {
        glyph_index: 1,
        width: 32.0,
        height: 32.0,
        bearing_x: 0.0,
        bearing_y: 0.0,
        advance: 32.0,
        uv_min_x: 0.0,
        uv_min_y: 0.0,
        uv_max_x: 1.0,
        uv_max_y: 1.0,
        format: GlyphAtlasFormat::Alpha,
    };
    let _ = list.add_atlas_glyph(
        glyph,
        Point::new(0.0, 0.0),
        Color {
            r: 1.0,
            g: 0.0,
            b: 0.0,
            a: 1.0,
        },
        1,
    );
    let _ = list.add_image_quad(
        Rect::new(32.0, 0.0, 32.0, 32.0),
        color_glyph_atlas_id(1),
        Color::WHITE,
        Point::new(0.0, 0.0),
        Point::new(1.0, 1.0),
    );
    DrawListSnapshot {
        vertices: list.vertices().to_vec(),
        indices: list.indices().to_vec(),
        batches: list.batches().to_vec(),
        logical_size: [64.0, 32.0],
        atlas_updates: vec![
            DrawListAtlasDirty::new(vec![alpha], 0, 0, 1, 1, 1, 1, 1, GlyphAtlasFormat::Alpha),
            DrawListAtlasDirty::new(
                vec![11, 200, 33, 255],
                0,
                0,
                1,
                1,
                1,
                1,
                color_glyph_atlas_id(1),
                GlyphAtlasFormat::Color,
            ),
        ],
        resources: list.resources.clone(),
    }
}

fn device_texture(device: &Arc<Device>, width: usize, height: usize) -> RhiResult<TextureResource> {
    TextureResource::new(
        device.clone(),
        TextureDescriptor::new(
            width,
            height,
            TextureFormat::Bgra8Unorm,
            TextureUsage::COLOR_TARGET | TextureUsage::TRANSFER_SOURCE,
        ),
    )
}

/// A missing provider and failed scene submission preserve the published
/// frame and pending atlas updates.
#[test]
fn failed_submission_preserves_frame_and_atlas() {
    if !gpu_resources_available() {
        return;
    }
    let device = Arc::new(Device::make(DeviceConfig::default()).expect("device"));
    let hud = HUDRouter::new();
    let mut scene = scene_with_provider(&device, Some(Box::new(hud.clone()))).expect("scene");
    let source = Arc::new(InGameDrawListSource::new());
    let probe = HUDSubmissionProbe::new(
        NativeInGameUIRenderer::new(device.clone(), source.clone()).expect("HUD renderer"),
    );
    hud.set_provider(None);

    let size = RenderDrawableSize::new(128, 64);
    let mut packet = MeshProbeScene::packet(size, 0);
    packet
        .in_game_canvas
        .rect(0.0, 0.0, 32.0, 32.0, InGameUIColor::RED);

    let mut missing = scene_with_provider(&device, None).expect("renderer without HUD");
    assert!(missing.render_checked(&packet).is_err());
    assert!(
        scene.color_texture().is_none(),
        "missing provider is rejected before scene allocation"
    );

    packet.in_game_canvas = InGameCanvas::new();
    scene.render_checked(&packet).expect("base frame");
    let previous = scene.current_viewport_surface_state();
    let color_texture = scene.color_texture().expect("color texture");
    let before = GridImage::readback(&device, color_texture, size).expect("base readback");

    hud.set_provider(Some(Box::new(probe.clone())));
    for failure in [Failure::Recording, Failure::Submission] {
        source.publish(snapshot(if failure == Failure::Recording {
            64
        } else {
            128
        }));
        probe.set_failure(failure);
        packet.frame_index += 1;
        assert!(scene.render_checked(&packet).is_err());
        assert_eq!(probe.acknowledgements(), 0);
        assert!(scene.current_viewport_surface_state() == previous);
        assert_eq!(scene.current_frame_stats().frame_index, 0);
        assert_eq!(
            GridImage::readback(&device, color_texture, size).expect("failed readback"),
            before
        );
    }

    // No producer tick or atlas re-publication: the consumed updates must
    // survive both an abandoned recording and backend submission rejection.
    probe.set_failure(Failure::None);
    packet.frame_index += 1;
    scene.render_checked(&packet).expect("recovered frame");
    assert_eq!(probe.acknowledgements(), 1);
    let actual = GridImage::readback(&device, color_texture, size).expect("recovered readback");
    // UI glyphs preserve the existing gamma-adjusted coverage contract.
    let coverage = (128.0f64 / 255.0).powf(0.75);
    let expected_red = (255.0 * coverage + f64::from(before[2]) * (1.0 - coverage)).round() as i64;
    assert!(
        (i64::from(actual[2]) - expected_red).abs() <= 1,
        "before={:?} actual={:?} expected={expected_red}",
        &before[0..4],
        &actual[0..4]
    );
    assert_eq!(
        &actual[(96 * 4)..(97 * 4)],
        [33, 200, 11, 255],
        "color atlas also survives failed submission"
    );
    assert_eq!(
        scene.current_frame_stats().active_passes.last(),
        Some(&RenderPassKind::InGameUI)
    );
}

/// Invisible atlas updates and a foreign-device target keep updates pending
/// for the next geometry.
#[test]
fn invisible_atlas_and_device_mismatch_keep_updates() {
    if !gpu_resources_available() {
        return;
    }
    let context = NativeViewportTestContext::new().expect("test context");
    let source = Arc::new(InGameDrawListSource::new());
    let consumer =
        NativeInGameUIRenderer::new(context.device.clone(), source.clone()).expect("rendering");
    let mut frame = snapshot(255);
    source.publish(frame.clone());
    let output = device_texture(&context.device, 256, 128).expect("output texture");
    let packet = MeshProbeScene::packet(RenderDrawableSize::new(128, 64), 0);

    let foreign = Arc::new(Device::make(DeviceConfig::default()).expect("foreign device"));
    assert!(
        consumer
            .record_in_game_ui(
                &packet,
                &packet.scene_snapshot,
                NativeInGameUITarget::new(
                    foreign,
                    CommandBuffer::new(),
                    RenderColorTarget::new(output.texture()),
                    TextureFormat::Bgra8Unorm,
                ),
            )
            .is_err()
    );
    assert_eq!(
        source
            .consume()
            .expect("pending snapshot")
            .atlas_updates
            .len(),
        2,
        "affinity validation happens before consuming snapshots"
    );

    frame.vertices.clear();
    frame.indices.clear();
    frame.batches.clear();
    source.publish(frame);
    let outcome = consumer.record_in_game_ui(
        &packet,
        &packet.scene_snapshot,
        NativeInGameUITarget::new(
            context.device.clone(),
            CommandBuffer::new(),
            RenderColorTarget::new(output.texture()),
            TextureFormat::Bgra8Unorm,
        ),
    );
    let Ok(outcome) = outcome else {
        panic!("empty geometry records");
    };
    assert!(outcome.recording.is_none());

    let mut frame = snapshot(255);
    frame.atlas_updates.clear();
    source.publish(frame);
    context.device.begin_frame().expect("begin frame");
    let mut commands = CommandBuffer::new();
    let recorded = consumer.record_in_game_ui(
        &packet,
        &packet.scene_snapshot,
        NativeInGameUITarget::new(
            context.device.clone(),
            commands,
            RenderColorTarget::clearing(output.texture(), [0.0, 0.0, 0.0, 1.0]),
            TextureFormat::Bgra8Unorm,
        ),
    );
    let Ok(outcome) = recorded else {
        context.device.end_frame();
        panic!("HUD recording failed");
    };
    commands = outcome.commands;
    let mut recording = outcome.recording.expect("recording token");
    let submitted = context
        .device
        .submit(&commands, QueueClass::Graphics, &[], &[], None);
    recording.did_submit();
    recording.did_submit();
    context.device.end_frame();
    submitted.expect("submit");

    let pixels = GridImage::readback(
        &context.device,
        output.texture(),
        RenderDrawableSize::new(256, 128),
    )
    .expect("readback");
    assert_eq!(&pixels[0..4], [0, 0, 255, 255]);
    assert_eq!(&pixels[(96 * 4)..(97 * 4)], [33, 200, 11, 255]);
    assert_eq!(
        &pixels[(192 * 4)..(193 * 4)],
        [0, 0, 0, 255],
        "HUD viewport uses packet extent rather than allocation capacity"
    );
    assert_eq!(
        &pixels[(100 * 256 * 4)..(100 * 256 * 4 + 4)],
        [0, 0, 0, 255]
    );
}
