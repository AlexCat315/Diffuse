//! `CinematicRendererTests` — Swift suite `CinematicRenderer`.

use std::sync::Mutex;

use diffuse_cinematic::aov_registry::{AovRegistry, AovSpec};
use diffuse_cinematic::path_tracer::{
    CameraRay, HitResult, PathTracer, PathTracerConfig, PathTracerState, Ray, SceneGeometry,
};
use diffuse_cinematic::sampling_strategy::{
    HaltonSampler, SamplingStrategy, SamplingStrategyPreset,
};
use diffuse_math::simd::simd_compat::{Float3, simd_length};

// MARK: - AOV Registry

// "AOVRegistry includes built-in AOVs"
#[test]
fn aov_registry_builtins() {
    let registry = AovRegistry::new();
    let ids: Vec<String> = registry
        .all_specs()
        .into_iter()
        .map(|spec| spec.id)
        .collect();
    for expected in [
        "beauty",
        "diffuse",
        "specular",
        "depth",
        "normal",
        "cryptomatte",
        "albedo",
        "emission",
        "ambient_occlusion",
        "motion_vector",
    ] {
        assert!(
            ids.contains(&expected.to_string()),
            "missing AOV {expected}"
        );
    }
}

// "AOVRegistry custom AOV registration"
#[test]
fn aov_registry_custom_register() {
    let registry = AovRegistry::new();
    registry.register(AovSpec::new("custom_heatmap", "Heatmap").with_channels(1));
    let spec = registry.spec("custom_heatmap").expect("custom AOV");
    assert_eq!(spec.name, "Heatmap");
    assert_eq!(spec.channel_count, 1);
}

// "AOVRegistry total channel count sums all specs"
#[test]
fn aov_registry_total_channels() {
    let registry = AovRegistry::new();
    let total: i64 = registry
        .all_specs()
        .iter()
        .map(|spec| spec.channel_count)
        .sum();
    assert_eq!(registry.total_channel_count(), total);
    assert!(registry.total_channel_count() > 0);
}

// MARK: - Sampling

// "Halton sampler produces values in [0, 1)"
#[test]
fn halton_sampler_range() {
    let sampler = HaltonSampler;
    for index in 0..100 {
        let sample = sampler.sample2d(index, 0);
        assert!(sample.x >= 0.0 && sample.x < 1.0);
        assert!(sample.y >= 0.0 && sample.y < 1.0);
    }
}

// "Halton sampler is deterministic"
#[test]
fn halton_sampler_deterministic() {
    let sampler = HaltonSampler;
    assert_eq!(sampler.sample2d(0, 0), sampler.sample2d(0, 0));
}

// "SamplingStrategyPreset creates appropriate strategies"
#[test]
fn sampling_strategy_presets() {
    for preset in SamplingStrategyPreset::ALL {
        let strategy = preset.create();
        let sample = strategy.sample2d(42, 7);
        assert!(sample.x >= 0.0 && sample.x <= 1.0);
        assert!(sample.y >= 0.0 && sample.y <= 1.0);
    }
}

// MARK: - Path tracer

// "PathTracerConfig default values match specification"
#[test]
fn path_tracer_config_defaults() {
    let config = PathTracerConfig::new();
    assert_eq!(config.max_bounces, 4);
    assert_eq!(config.samples_per_pixel, 64);
    assert_eq!(config.russian_roulette_depth, 3);
    assert_eq!(config.clamp_indirect, 10.0);
}

// "PathTracer initial state has zero completed samples"
#[test]
fn path_tracer_initial_state() {
    let mut config = PathTracerConfig::new();
    config.samples_per_pixel = 64;
    let tracer = PathTracer::new(config);
    let state = tracer.state();
    assert_eq!(state.completed_samples, 0);
    assert_eq!(state.total_samples, 64);
    assert!(!state.is_complete());
}

// "PathTracerState progress tracks completion"
#[test]
fn path_tracer_state_progress() {
    let mut state = PathTracerState::new(100);
    assert_eq!(state.progress(), 0.0);
    assert!(!state.is_complete());

    state.completed_samples = 50;
    assert_eq!(state.progress(), 0.5);
    assert!(!state.is_complete());

    state.completed_samples = 100;
    assert_eq!(state.progress(), 1.0);
    assert!(state.is_complete());
}

// "Ray construction normalizes direction"
#[test]
fn ray_normalization() {
    let ray = Ray::new(Float3::ZERO, Float3::new(0.0, 2.0, 0.0));
    assert!((simd_length(ray.direction) - 1.0).abs() < 0.001);
}

// "Ray point-at computes correct position on ray"
#[test]
fn ray_point_at() {
    let ray = Ray::new(Float3::new(1.0, 0.0, 0.0), Float3::new(0.0, 0.0, 1.0));
    let point = ray.point_at(5.0);
    assert_eq!(point.x, 1.0);
    assert_eq!(point.y, 0.0);
    assert_eq!(point.z, 5.0);
}

struct EmptyPathTraceGeometry;

impl SceneGeometry for EmptyPathTraceGeometry {
    fn intersect(&self, _ray: &Ray) -> Option<HitResult> {
        None
    }

    fn bounds(&self) -> (Float3, Float3) {
        (Float3::ZERO, Float3::ZERO)
    }
}

struct DirectionEmissionGeometry;

impl SceneGeometry for DirectionEmissionGeometry {
    fn intersect(&self, ray: &Ray) -> Option<HitResult> {
        Some(HitResult {
            t: 1.0,
            position: ray.point_at(1.0),
            normal: Float3::new(0.0, 1.0, 0.0),
            albedo: Float3::ZERO,
            emission: Float3::new(
                (ray.direction.x + 1.0) * 0.5,
                (ray.direction.y + 1.0) * 0.5,
                ray.direction.z.abs(),
            ),
            roughness: 0.5,
            metallic: 0.0,
        })
    }

    fn bounds(&self) -> (Float3, Float3) {
        (Float3::splat(-1.0), Float3::splat(1.0))
    }
}

// "Path tracer returns the configured environment and tolerates a degenerate camera"
#[test]
fn path_tracer_environment_and_degenerate_camera() {
    let environment = Float3::new(0.2, 0.35, 0.5);
    let mut config = PathTracerConfig::new();
    config.max_bounces = 0;
    config.samples_per_pixel = 1;
    config.environment_color = environment;
    let tracer = PathTracer::new(config);
    let mut framebuffer = vec![0.0f32; 2 * 2 * 3];
    let mut geometry = EmptyPathTraceGeometry;

    let completed = tracer.accumulate_pass(
        &mut framebuffer,
        2,
        2,
        Float3::ZERO,
        Float3::ZERO,
        Float3::ZERO,
        f32::NAN,
        Some(f32::NAN),
        &mut geometry,
        None,
    );
    assert!(completed);

    for pixel in 0..4 {
        assert!((framebuffer[pixel * 3] - environment.x).abs() < 0.000_001);
        assert!((framebuffer[pixel * 3 + 1] - environment.y).abs() < 0.000_001);
        assert!((framebuffer[pixel * 3 + 2] - environment.z).abs() < 0.000_001);
    }
}

struct RowCancellationProbe {
    cancel_on_check: usize,
    checks: Mutex<usize>,
}

impl RowCancellationProbe {
    fn new(cancel_on_check: usize) -> Self {
        RowCancellationProbe {
            cancel_on_check,
            checks: Mutex::new(0),
        }
    }

    fn should_cancel(&self) -> bool {
        let mut checks = self.checks.lock().expect("probe");
        *checks += 1;
        *checks >= self.cancel_on_check
    }
}

// "Path tracer checks cancellation between image rows and does not advance progress"
#[test]
fn path_tracer_cancellation_between_rows() {
    let mut config = PathTracerConfig::new();
    config.max_bounces = 0;
    config.samples_per_pixel = 1;
    config.environment_color = Float3::new(0.2, 0.35, 0.5);
    let tracer = PathTracer::new(config);
    let probe = RowCancellationProbe::new(2);
    let mut framebuffer = vec![0.0f32; 2 * 2 * 3];
    let mut geometry = EmptyPathTraceGeometry;

    let completed = tracer.accumulate_pass(
        &mut framebuffer,
        2,
        2,
        Float3::ZERO,
        Float3::new(0.0, 0.0, -1.0),
        Float3::new(0.0, 1.0, 0.0),
        core::f32::consts::PI / 4.0,
        None,
        &mut geometry,
        Some(&|| probe.should_cancel()),
    );

    assert!(!completed);
    assert_eq!(tracer.state().completed_samples, 0);
    assert!(framebuffer[0] > 0.0);
    assert_eq!(framebuffer[6], 0.0);
}

// "renderPass projects pixel coordinates instead of reusing one ray"
#[test]
fn render_pass_projects_pixel_coordinates() {
    let mut config = PathTracerConfig::new();
    config.max_bounces = 0;
    config.samples_per_pixel = 1;
    let tracer = PathTracer::new(config);
    let mut geometry = DirectionEmissionGeometry;

    let left = tracer.render_pass(
        4,
        1,
        CameraRay::new(Float3::ZERO, Float3::new(0.0, 0.0, -1.0), 0, 0),
        &mut geometry,
        0,
    );
    let right = tracer.render_pass(
        4,
        1,
        CameraRay::new(Float3::ZERO, Float3::new(0.0, 0.0, -1.0), 3, 0),
        &mut geometry,
        0,
    );

    assert!((left.x - right.x).abs() > 0.01);
    assert!(left.x.is_finite() && right.x.is_finite());
}
