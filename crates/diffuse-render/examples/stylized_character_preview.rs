//! Translation of Demos/StylizedCharacterPreviewDemo/main.swift.
//!
//! Renders the four character preview states through the migrated native
//! renderer, offscreen with the stylized look, and prints one stats line per
//! state.

use std::collections::BTreeMap;

use cove_graphics::rhi::{Device, DeviceConfig};
use cove_logging::{LogSystem, LoggingConfiguration};
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_scene::media::animation::JointPaletteMap;
use diffuse_scene::rendering::render_scene::{
    RenderCamera, RenderCameraProjection, RenderEnvironment, RenderInstance, RenderMaterial,
    RenderScene,
};
use diffuse_scene::scene_runtime::SceneRuntimeSnapshot;

use diffuse_render::core::frame::render_packet::{RenderDrawableSize, RenderPacket};
use diffuse_render::core::render_settings::{RenderSettings, StylizedCharacterStyle};
use diffuse_render::native::native_renderer::NativeRenderer;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CharacterPreviewState {
    Idle,
    Attack,
    Hit,
    Death,
}

impl CharacterPreviewState {
    /// Swift's `CaseIterable` order.
    const ALL: [CharacterPreviewState; 4] = [
        CharacterPreviewState::Idle,
        CharacterPreviewState::Attack,
        CharacterPreviewState::Hit,
        CharacterPreviewState::Death,
    ];

    fn raw_value(self) -> &'static str {
        match self {
            CharacterPreviewState::Idle => "idle",
            CharacterPreviewState::Attack => "attack",
            CharacterPreviewState::Hit => "hit",
            CharacterPreviewState::Death => "death",
        }
    }
}

struct PreviewConfig {
    frames_per_state: usize,
    drawable_size: RenderDrawableSize,
}

impl Default for PreviewConfig {
    fn default() -> Self {
        PreviewConfig {
            frames_per_state: 18,
            drawable_size: RenderDrawableSize::new(1280, 720),
        }
    }
}

fn parse_config(arguments: &[String]) -> PreviewConfig {
    let mut config = PreviewConfig::default();
    if let Some(index) = arguments.iter().position(|argument| argument == "--frames")
        && let Some(frames) = arguments
            .get(index + 1)
            .and_then(|value| value.parse::<usize>().ok())
    {
        config.frames_per_state = frames.max(1);
    }
    config
}

fn translation(value: Float3) -> Float4x4 {
    let mut matrix = MATRIX_IDENTITY_FLOAT4X4;
    matrix.columns[3] = Float4::new(value.x, value.y, value.z, 1.0);
    matrix
}

fn scale(value: Float3) -> Float4x4 {
    let mut matrix = MATRIX_IDENTITY_FLOAT4X4;
    matrix.columns[0].x = value.x;
    matrix.columns[1].y = value.y;
    matrix.columns[2].z = value.z;
    matrix
}

fn rotation_y(radians: f32) -> Float4x4 {
    let c = radians.cos();
    let s = radians.sin();
    Float4x4::from_columns([
        Float4::new(c, 0.0, -s, 0.0),
        Float4::new(0.0, 1.0, 0.0, 0.0),
        Float4::new(s, 0.0, c, 0.0),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    ])
}

fn rotation_z(radians: f32) -> Float4x4 {
    let c = radians.cos();
    let s = radians.sin();
    Float4x4::from_columns([
        Float4::new(c, s, 0.0, 0.0),
        Float4::new(-s, c, 0.0, 0.0),
        Float4::new(0.0, 0.0, 1.0, 0.0),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    ])
}

fn character_transform(state: CharacterPreviewState, phase: f32) -> Float4x4 {
    match state {
        CharacterPreviewState::Idle => {
            let bob = (phase * core::f32::consts::PI * 2.0).sin() * 0.08;
            translation(Float3::new(0.0, bob, 0.0))
                * rotation_y((phase * core::f32::consts::PI * 2.0).sin() * 0.08)
        }
        CharacterPreviewState::Attack => {
            let lunge = (phase.min(0.55) / 0.55 * core::f32::consts::PI).sin() * 0.85;
            translation(Float3::new(lunge, 0.0, -0.15))
                * rotation_z(-0.28)
                * scale(Float3::new(1.06, 0.96, 1.0))
        }
        CharacterPreviewState::Hit => {
            let recoil = (phase * core::f32::consts::PI).sin() * -0.55;
            translation(Float3::new(recoil, 0.05, 0.0))
                * rotation_z(0.18)
                * scale(Float3::new(0.96, 1.04, 1.0))
        }
        CharacterPreviewState::Death => {
            let fall = (phase * 1.15).min(1.0);
            translation(Float3::new(-0.25 * fall, -0.7 * fall, 0.0))
                * rotation_z(-1.15 * fall)
                * scale(Float3::new(1.0, 1.0 - 0.32 * fall, 1.0))
        }
    }
}

fn make_scene(state: CharacterPreviewState, phase: f32) -> RenderScene {
    let camera = RenderCamera::with_parameters(
        Float3::new(0.0, 2.3, 7.0),
        Float3::new(0.0, 0.6, 0.0),
        Float3::new(0.0, 1.0, 0.0),
        core::f32::consts::PI / 4.5,
        1.0,
        0.1,
        50.0,
        RenderCameraProjection::Perspective,
        10.0,
    );
    RenderScene::new(
        camera,
        vec![RenderInstance::from_mesh_index(
            1,
            character_transform(state, phase),
            Float3::new(1.0, 1.0, 1.0),
            RenderMaterial::fallback(),
            None,
        )],
        Vec::new(),
        RenderEnvironment::new(Float3::new(0.03, 0.03, 0.035), 1.0, 1.0),
        Vec::new(),
        Vec::new(),
        Vec::new(),
        None,
    )
}

fn main() {
    let mut logging_configuration = LoggingConfiguration::default();
    let environment: BTreeMap<String, String> = std::env::vars().collect();
    if let Err(error) = logging_configuration.apply_environment(&environment) {
        eprintln!("logging configuration failed: {error}");
        return;
    }
    if let Err(error) = LogSystem::bootstrap(None, logging_configuration, None) {
        eprintln!("logging bootstrap failed: {error}");
        return;
    }

    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let config = parse_config(&arguments);
    let device = match Device::make(DeviceConfig {
        enable_validation: false,
        ..DeviceConfig::default()
    }) {
        Ok(device) => device,
        Err(error) => {
            eprintln!("device creation failed: {error}");
            return;
        }
    };

    let mut renderer = match NativeRenderer::new(
        &device,
        None,
        AssetRegistry::shared(),
        None,
        &RenderSettings::default(),
        &[64],
    ) {
        Ok(renderer) => renderer,
        Err(error) => {
            eprintln!("renderer creation failed: {error}");
            return;
        }
    };
    renderer.initialize();

    let settings = RenderSettings::configured(|settings| {
        settings.post_processing.bloom = false;
        settings.viewport.offscreen = true;
        settings.stylization.enabled = true;
        settings.stylization.style = StylizedCharacterStyle::colorful_ink_card();
    });

    let mut frame_index = 0usize;
    for state in CharacterPreviewState::ALL {
        for local_frame in 0..config.frames_per_state {
            let phase =
                local_frame as f32 / (config.frames_per_state.saturating_sub(1)).max(1) as f32;
            let packet = RenderPacket {
                frame_index,
                delta_time: 1.0 / 60.0,
                drawable_size: config.drawable_size,
                scene: make_scene(state, phase),
                scene_snapshot: SceneRuntimeSnapshot::new(1, frame_index as u64),
                render_settings: settings,
                simulation_time_seconds: frame_index as f64 / 60.0,
                joint_palette_map: JointPaletteMap::new(BTreeMap::new()),
                in_game_canvas: diffuse_kernel::in_game_canvas::InGameCanvas::new(),
                mipmapped_viewport_output: false,
            };
            if let Err(error) = renderer.render_checked(&packet) {
                eprintln!("render failed: {error}");
                LogSystem::flush();
                return;
            }
            frame_index += 1;
        }
        let stats = renderer.current_frame_stats();
        let passes_joined = stats
            .active_passes
            .iter()
            .map(|kind| kind.raw_value())
            .collect::<Vec<&'static str>>()
            .join(",");
        println!(
            "[stylized-character-preview] state={} frames={} passes={passes_joined} drawCalls={}",
            state.raw_value(),
            config.frames_per_state,
            stats.draw_call_count
        );
    }

    if let Err(error) = device.wait_until_idle() {
        eprintln!("device idle wait failed: {error}");
    }
    LogSystem::flush();
}
