//! Ported from `Editor/Tests/EditorCoreTests/Rendering/NativeInGameUIBenchmarkTests.swift`.
//!
//! Opt-in release benchmark: set `COVE_NATIVE_HUD_BENCHMARK=1`. Runs in debug
//! too, but the measured numbers are only meaningful in a release build.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Instant;

use cove_graphics::rhi::{Device, DeviceConfig, RhiResult};
use cove_ui_compose::primitives::text::Text;
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_kernel::in_game_canvas::InGameUIColor;
use diffuse_render::RenderDrawableSize;
use diffuse_render::RenderPacket;
use diffuse_render::RenderSettings;
use diffuse_render::core::frame::render_frame_plan::RenderPassKind;
use diffuse_render::core::render_stats::RenderFrameStats;
use diffuse_render::native::native_renderer::NativeRenderer;
use diffuse_render::surface::in_game_ui_providing::{
    InGameUIProviding, InGameUIRecordingOutcome, InGameUIRecordingOutcomeError,
    NativeInGameUITarget,
};
use diffuse_render_validation::GridImage;
use diffuse_render_validation::PostProbeScene;
use diffuse_render_validation::probes::mesh_probe_scene::MeshProbeScene;

use diffuse_scene::scene_runtime::SceneRuntimeSnapshot;

use super::hud_router::HUDRouter;
use crate::rendering::hud::in_game_ui_host::InGameUIHost;

#[derive(Clone)]
struct SharedHud(Arc<InGameUIHost>);

impl InGameUIProviding for SharedHud {
    fn record_in_game_ui(
        &self,
        packet: &RenderPacket,
        snapshot: &SceneRuntimeSnapshot,
        target: NativeInGameUITarget,
    ) -> Result<InGameUIRecordingOutcome, InGameUIRecordingOutcomeError> {
        self.0.record_in_game_ui(packet, snapshot, target)
    }
}

const FRAMES: usize = 180;
const WARMUP: usize = 30;
const REPEATS: usize = 3;
const LOGICAL_WIDTH: u32 = 1280;
const LOGICAL_HEIGHT: u32 = 720;

#[derive(serde::Serialize)]
struct HudTiming {
    #[serde(rename = "p50Microseconds")]
    p50_microseconds: f64,
    #[serde(rename = "p95Microseconds")]
    p95_microseconds: f64,
    #[serde(rename = "sampleCount")]
    sample_count: usize,
}

impl HudTiming {
    fn new(mut samples: Vec<f64>) -> Self {
        samples.sort_by(|lhs, rhs| lhs.total_cmp(rhs));
        let percentile = |fraction: f64| -> f64 {
            let index = ((samples.len() as f64 * fraction).ceil() as usize).saturating_sub(1);
            samples[index.min(samples.len() - 1)]
        };
        HudTiming {
            p50_microseconds: percentile(0.5),
            p95_microseconds: percentile(0.95),
            sample_count: samples.len(),
        }
    }
}

#[derive(serde::Serialize)]
struct HudBenchmarkResult {
    backend: String,
    #[serde(rename = "cpuTickAndScene")]
    cpu_tick_and_scene: HudTiming,
    #[serde(rename = "cpuScene")]
    cpu_scene: HudTiming,
    #[serde(rename = "cpuHUDEncode")]
    cpu_hud_encode: HudTiming,
    #[serde(rename = "completedBatch")]
    completed_batch: HudTiming,
    #[serde(rename = "passFrames")]
    pass_frames: BTreeMap<String, usize>,
    #[serde(rename = "passDraws")]
    pass_draws: BTreeMap<String, usize>,
}

fn packet(post: bool, size: RenderDrawableSize, frame: i64) -> RenderPacket {
    let mut packet = if post {
        PostProbeScene::packet(size, 0)
    } else {
        MeshProbeScene::packet(size, 0)
    };
    packet.frame_index = frame;
    packet.scene.camera.eye.x += (frame % 11) as f32 * 0.002;
    packet.render_settings.post_processing.ssr = false;
    packet.render_settings.post_processing.taa = false;
    for index in 0..40 {
        let x = (index % 8) as f32 * 155.0 + 12.0;
        let y = (index / 8) as f32 * 130.0 + 40.0;
        packet.in_game_canvas.rect_rounded(
            x,
            y,
            144.0,
            96.0,
            InGameUIColor {
                r: 0.06,
                g: 0.09,
                b: 0.15,
                a: 0.8,
            },
            6.0,
        );
        packet.in_game_canvas.label_styled(
            format!("Unit {index} 中🙂"),
            x + 8.0,
            y + 8.0,
            16.0,
            InGameUIColor::WHITE,
        );
        packet.in_game_canvas.progress_bar(
            x + 8.0,
            y + 64.0,
            124.0,
            12.0,
            ((frame + index as i64) % 60) as f32 / 60.0,
        );
    }
    packet
}

fn measure(
    scene: &mut NativeRenderer,
    native_hud: &InGameUIHost,
    device: &Arc<Device>,
    size: RenderDrawableSize,
    scale: f32,
    post: bool,
) -> RhiResult<HudBenchmarkResult> {
    let mut render = |frame: i64| -> RhiResult<RenderFrameStats> {
        let p = packet(post, size, frame);
        native_hud.tick(
            LOGICAL_WIDTH,
            LOGICAL_HEIGHT,
            scale,
            p.in_game_canvas.clone(),
        );
        scene.render_checked(&p)?;
        assert!(
            !scene.last_frame_used_opaque_cache(),
            "the benchmark HUD changes every frame"
        );
        Ok(scene.current_frame_stats())
    };
    for frame in 0..WARMUP {
        let _ = render(frame as i64)?;
        if (frame + 1) % 3 == 0 {
            device.wait_until_idle()?;
        }
    }
    device.wait_until_idle()?;

    let mut cpu = Vec::with_capacity(FRAMES * REPEATS);
    let mut cpu_scene = Vec::with_capacity(FRAMES * REPEATS);
    let mut hud = Vec::with_capacity(FRAMES * REPEATS);
    let mut completed = Vec::with_capacity(REPEATS);
    let mut pass_frames: BTreeMap<String, usize> = BTreeMap::new();
    let mut pass_draws: BTreeMap<String, usize> = BTreeMap::new();
    for repetition in 0..REPEATS {
        let batch_start = Instant::now();
        for frame in 0..FRAMES {
            let before = Instant::now();
            let stats = render((WARMUP + repetition * FRAMES + frame) as i64)?;
            cpu.push(before.elapsed().as_secs_f64() * 1_000_000.0);
            cpu_scene.push(stats.cpu_frame_total_ns as f64 / 1000.0);
            hud.push(
                stats
                    .pass_encode_ns
                    .get(&RenderPassKind::InGameUI)
                    .copied()
                    .unwrap_or(0) as f64
                    / 1000.0,
            );
            for (kind, draws) in &stats.pass_draw_call_counts {
                *pass_frames.entry(kind.raw_value().to_string()).or_insert(0) += 1;
                *pass_draws.entry(kind.raw_value().to_string()).or_insert(0) += *draws as usize;
            }
            if (frame + 1) % 3 == 0 {
                device.wait_until_idle()?;
            }
        }
        completed.push(batch_start.elapsed().as_secs_f64() * 1_000_000.0 / FRAMES as f64);
    }

    Ok(HudBenchmarkResult {
        backend: format!("native-{}", device.backend_api().display_name()),
        cpu_tick_and_scene: HudTiming::new(cpu),
        cpu_scene: HudTiming::new(cpu_scene),
        cpu_hud_encode: HudTiming::new(hud),
        completed_batch: HudTiming::new(completed),
        pass_frames,
        pass_draws,
    })
}

/// Release scene and HUD workload. Opt in with `COVE_NATIVE_HUD_BENCHMARK=1`.
#[test]
fn release_scene_and_hud_workload() {
    if std::env::var("COVE_NATIVE_HUD_BENCHMARK").as_deref() != Ok("1") {
        return;
    }
    if cfg!(debug_assertions) {
        panic!("run the HUD benchmark with `cargo test --release`");
    }
    if std::env::var_os("COVE_RESOURCE_PATH").is_none() {
        return;
    }
    let device = Arc::new(
        Device::make(DeviceConfig {
            enable_validation: false,
            frames_in_flight: 3,
            ..DeviceConfig::default()
        })
        .expect("benchmark device"),
    );
    let hud = HUDRouter::new();
    let mut scene = NativeRenderer::new(
        &device,
        None,
        AssetRegistry::shared(),
        Some(Box::new(hud.clone())),
        &RenderSettings::default(),
        &[],
    )
    .expect("benchmark renderer");
    let native_hud = Arc::new(InGameUIHost::new(device.clone()).expect("benchmark HUD"));
    native_hud.set_root_view(Text::new("Cove NativeRHI HUD 中🙂"));
    hud.set_provider(Some(Box::new(SharedHud(native_hud.clone()))));

    for post in [false, true] {
        for size in [
            RenderDrawableSize::new(1280, 720),
            RenderDrawableSize::new(1920, 1080),
        ] {
            let scale = size.width as f32 / LOGICAL_WIDTH as f32;
            let result = measure(&mut scene, &native_hud, &device, size, scale, post)
                .expect("measured workload");
            let color_texture = scene.color_texture().expect("benchmark color");
            let actual = GridImage::readback(&device, color_texture, size).expect("readback");
            assert!(
                result
                    .pass_draws
                    .get(RenderPassKind::InGameUI.raw_value())
                    .copied()
                    .unwrap_or(0)
                    > 540
            );
            assert_eq!(actual.len(), size.width as usize * size.height as usize * 4);

            let report = serde_json::json!({
                "device": device.device_name(),
                "operatingSystem": std::env::consts::OS,
                "buildConfiguration": if cfg!(debug_assertions) { "debug" } else { "release" },
                "timingMethod": "Main-thread HUD tick + scene CPU duration; GPU completion every three frames; no GPU timestamps or presentation",
                "width": size.width,
                "height": size.height,
                "post": post,
                "logicalWidth": LOGICAL_WIDTH,
                "logicalHeight": LOGICAL_HEIGHT,
                "frames": FRAMES,
                "warmup": WARMUP,
                "repeats": REPEATS,
                "results": [result],
            });
            let root = std::env::var_os("COVE_NATIVE_HUD_BENCHMARK_OUTPUT")
                .map(std::path::PathBuf::from)
                .unwrap_or_else(std::env::temp_dir);
            std::fs::create_dir_all(&root).expect("benchmark output directory");
            let file = root.join(format!(
                "native-hud-{}-m1-{}.json",
                if post { "post" } else { "mesh" },
                size.height
            ));
            std::fs::write(
                file,
                serde_json::to_vec_pretty(&report).expect("benchmark JSON"),
            )
            .expect("benchmark report");
        }
    }
}
