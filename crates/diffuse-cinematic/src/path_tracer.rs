//! `PathTracer` — the progressive CPU path tracer.
//!
//! Swift drew Russian-roulette and hemisphere samples from `Float.random(in:)`.
//! MIGRATION.md forbids new crates, so this file carries a small splitmix64
//! generator seeded per tracer; sampling stays in `[0, 1)` and the shapes of the
//! estimators are unchanged.

use diffuse_math::simd::simd_compat::{Float2, Float3, simd_cross, simd_length, simd_normalize};
use std::sync::Mutex;

use crate::aov_registry::AovRegistry;
use crate::sampling_strategy::{HaltonSampler, SamplingStrategy};

#[derive(Clone, Debug, PartialEq)]
pub struct PathTracerState {
    pub completed_samples: usize,
    pub total_samples: usize,
}

impl PathTracerState {
    #[inline]
    pub fn new(total_samples: usize) -> Self {
        PathTracerState {
            completed_samples: 0,
            total_samples,
        }
    }

    #[inline]
    pub fn is_complete(&self) -> bool {
        self.completed_samples >= self.total_samples
    }

    pub fn progress(&self) -> f32 {
        if self.total_samples == 0 {
            return 0.0;
        }
        self.completed_samples as f32 / self.total_samples as f32
    }
}

/// `Ray` with the cached inverse direction Swift precomputed.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Ray {
    pub origin: Float3,
    pub direction: Float3,
    pub inv_direction: Float3,
}

impl Ray {
    pub fn new(origin: Float3, direction: Float3) -> Self {
        let direction = normalized_or_fallback(direction, Float3::new(0.0, 0.0, -1.0));
        Ray {
            origin,
            direction,
            inv_direction: Float3::new(
                1.0 / safe_component(direction.x),
                1.0 / safe_component(direction.y),
                1.0 / safe_component(direction.z),
            ),
        }
    }

    #[inline]
    pub fn point_at(&self, t: f32) -> Float3 {
        self.origin + self.direction * t
    }
}

fn safe_component(value: f32) -> f32 {
    if value.abs() > 1e-8 { value } else { 1e-8 }
}

/// A camera sample for `render_pass`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CameraRay {
    pub origin: Float3,
    pub direction: Float3,
    pub pixel_x: usize,
    pub pixel_y: usize,
}

impl CameraRay {
    #[inline]
    pub fn new(origin: Float3, direction: Float3, pixel_x: usize, pixel_y: usize) -> Self {
        CameraRay {
            origin,
            direction,
            pixel_x,
            pixel_y,
        }
    }
}

/// Geometry the tracer can intersect.
pub trait SceneGeometry: Send {
    fn intersect(&self, ray: &Ray) -> Option<HitResult>;
    fn bounds(&self) -> (Float3, Float3);
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HitResult {
    pub t: f32,
    pub position: Float3,
    pub normal: Float3,
    pub albedo: Float3,
    pub emission: Float3,
    pub roughness: f32,
    pub metallic: f32,
}

impl HitResult {
    /// Swift's default-argument initializer, including every default value.
    pub fn new() -> Self {
        HitResult {
            t: f32::INFINITY,
            position: Float3::ZERO,
            normal: Float3::new(0.0, 0.0, 1.0),
            albedo: Float3::new(0.8, 0.8, 0.8),
            emission: Float3::ZERO,
            roughness: 0.5,
            metallic: 0.0,
        }
    }

    #[inline]
    pub fn is_hit(&self) -> bool {
        self.t < f32::INFINITY
    }
}

impl Default for HitResult {
    fn default() -> Self {
        Self::new()
    }
}

pub struct PathTracerConfig {
    pub max_bounces: usize,
    pub samples_per_pixel: usize,
    pub russian_roulette_depth: usize,
    pub clamp_indirect: f32,
    pub sampling_strategy: Box<dyn SamplingStrategy>,
    pub environment_color: Float3,
}

impl PathTracerConfig {
    /// Swift defaults: 4 bounces, 64 spp, roulette from depth 3, indirect clamp
    /// 10, the Halton sampler and the (0.08, 0.1, 0.14) environment.
    pub fn new() -> Self {
        PathTracerConfig {
            max_bounces: 4,
            samples_per_pixel: 64,
            russian_roulette_depth: 3,
            clamp_indirect: 10.0,
            sampling_strategy: Box::new(HaltonSampler),
            environment_color: Float3::new(0.08, 0.1, 0.14),
        }
    }
}

impl Default for PathTracerConfig {
    fn default() -> Self {
        Self::new()
    }
}

/// splitmix64, used where Swift called `Float.random(in:)`.
pub(crate) struct Rng {
    state: u64,
}

impl Rng {
    #[inline]
    fn new(seed: u64) -> Self {
        Rng { state: seed }
    }

    #[inline]
    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)`.
    #[inline]
    fn next_unit(&mut self) -> f32 {
        // 24 mantissa bits, matching a single-precision uniform draw.
        ((self.next_u64() >> 40) as f32) / 16_777_216.0
    }
}

pub struct PathTracer {
    pub config: PathTracerConfig,
    pub aov_registry: AovRegistry,
    state: Mutex<PathTracerState>,
    rng: Mutex<Rng>,
}

impl PathTracer {
    /// Swift defaults: `PathTracerConfig()` and `AOVRegistry()`.
    pub fn new(config: PathTracerConfig) -> Self {
        let total = config.samples_per_pixel;
        PathTracer {
            config,
            aov_registry: AovRegistry::new(),
            state: Mutex::new(PathTracerState::new(total)),
            // Seeded so runs are reproducible; the tracer is a preview renderer,
            // not a cryptographic sampler.
            rng: Mutex::new(Rng::new(0x5EED_1234_ABCD_0001)),
        }
    }

    pub fn with_defaults() -> Self {
        Self::new(PathTracerConfig::new())
    }

    fn state_lock(&self) -> std::sync::MutexGuard<'_, PathTracerState> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    fn rng_lock(&self) -> std::sync::MutexGuard<'_, Rng> {
        self.rng.lock().unwrap_or_else(|error| error.into_inner())
    }

    /// A snapshot of the progressive state.
    pub fn state(&self) -> PathTracerState {
        self.state_lock().clone()
    }

    /// Renders one pixel for the given sample.
    pub fn render_pass(
        &self,
        width: usize,
        height: usize,
        camera: CameraRay,
        geometry: &mut dyn SceneGeometry,
        sample: usize,
    ) -> Float3 {
        if width == 0 || height == 0 {
            return self.config.environment_color;
        }
        let jitter = self.config.sampling_strategy.sample2d(
            sample * width * height + camera.pixel_y * width + camera.pixel_x,
            sample,
        );
        let u = (camera.pixel_x as f32 + jitter.x) / width as f32;
        let v = (camera.pixel_y as f32 + jitter.y) / height as f32;
        let projection = SimpleCamera::new(
            camera.origin,
            camera.direction,
            Float3::new(0.0, 1.0, 0.0),
            core::f32::consts::PI / 4.0,
            width as f32 / height as f32,
        );
        let ray = projection.ray(Float2::new(u, v));
        self.trace(&ray, geometry, 0)
    }

    /// Accumulates one sample per pixel into `framebuffer` (RGB triples).
    /// Returns `false` when the pass was cancelled or the buffer was too small.
    #[allow(clippy::too_many_arguments)]
    pub fn accumulate_pass(
        &self,
        framebuffer: &mut [f32],
        width: usize,
        height: usize,
        camera_origin: Float3,
        camera_forward: Float3,
        camera_up: Float3,
        camera_fov_y_radians: f32,
        camera_aspect_ratio: Option<f32>,
        geometry: &mut dyn SceneGeometry,
        should_cancel: Option<&dyn Fn() -> bool>,
    ) -> bool {
        if width == 0 || height == 0 {
            return false;
        }
        let camera = SimpleCamera::new(
            camera_origin,
            camera_forward,
            camera_up,
            camera_fov_y_radians,
            camera_aspect_ratio.unwrap_or(if height > 0 {
                width as f32 / height as f32
            } else {
                1.0
            }),
        );
        let sample_index = self.state_lock().completed_samples;
        let pixel_count = width * height;
        if framebuffer.len() < pixel_count * 3 {
            return false;
        }

        for y in 0..height {
            if let Some(should_cancel) = should_cancel
                && should_cancel()
            {
                return false;
            }
            for x in 0..width {
                let jitter = self
                    .config
                    .sampling_strategy
                    .sample2d(x + y * width, sample_index);
                let u = (x as f32 + jitter.x) / width as f32;
                let v = (y as f32 + jitter.y) / height as f32;
                let ray = camera.ray(Float2::new(u, v));
                let color = self.trace(&ray, geometry, 0);
                let index = (y * width + x) * 3;
                let inv_samples = 1.0 / (sample_index + 1) as f32;
                framebuffer[index] =
                    (framebuffer[index] * sample_index as f32 + color.x) * inv_samples;
                framebuffer[index + 1] =
                    (framebuffer[index + 1] * sample_index as f32 + color.y) * inv_samples;
                framebuffer[index + 2] =
                    (framebuffer[index + 2] * sample_index as f32 + color.z) * inv_samples;
            }
        }
        self.state_lock().completed_samples += 1;
        true
    }

    fn trace(&self, ray: &Ray, geometry: &mut dyn SceneGeometry, depth: usize) -> Float3 {
        let Some(hit) = geometry.intersect(ray) else {
            return self.config.environment_color;
        };

        let mut color = hit.emission;

        if depth >= self.config.russian_roulette_depth {
            let survival_probability = hit
                .albedo
                .x
                .max(hit.albedo.y)
                .max(hit.albedo.z)
                .clamp(0.1, 1.0);
            let draw = self.rng_lock().next_unit();
            if draw > survival_probability {
                return color;
            }
        }

        if depth >= self.config.max_bounces {
            return color;
        }

        // Simple diffuse bounce (Lambertian).
        let bounce_dir = cosine_weighted_hemisphere(hit.normal, &mut self.rng_lock());
        let bounce_ray = Ray::new(hit.position + hit.normal * 0.001, bounce_dir);
        let indirect_color = self.trace(&bounce_ray, geometry, depth + 1);

        // Clamp fireflies.
        let clamped_indirect = Float3::new(
            indirect_color.x.min(self.config.clamp_indirect),
            indirect_color.y.min(self.config.clamp_indirect),
            indirect_color.z.min(self.config.clamp_indirect),
        );
        color += hit.albedo * clamped_indirect;

        color
    }
}

impl Default for PathTracer {
    fn default() -> Self {
        Self::with_defaults()
    }
}

/// The pinhole camera Swift kept file-private.
struct SimpleCamera {
    origin: Float3,
    forward: Float3,
    right: Float3,
    up: Float3,
    half_height: f32,
    half_width: f32,
}

impl SimpleCamera {
    fn new(
        origin: Float3,
        forward: Float3,
        up: Float3,
        fov_y_radians: f32,
        aspect_ratio: f32,
    ) -> Self {
        let safe_forward = normalized_or_fallback(forward, Float3::new(0.0, 0.0, -1.0));
        let safe_up = normalized_or_fallback(up, Float3::new(0.0, 1.0, 0.0));
        let mut right_raw = simd_cross(safe_forward, safe_up);
        if simd_length(right_raw) <= 0.000_001 {
            let alternate_up = if safe_forward.y.abs() < 0.99 {
                Float3::new(0.0, 1.0, 0.0)
            } else {
                Float3::new(1.0, 0.0, 0.0)
            };
            right_raw = simd_cross(safe_forward, alternate_up);
        }
        let safe_right = normalized_or_fallback(right_raw, Float3::new(1.0, 0.0, 0.0));
        let up_normalized = normalized_or_fallback(
            simd_cross(safe_right, safe_forward),
            Float3::new(0.0, 1.0, 0.0),
        );
        let safe_fov = if fov_y_radians.is_finite() {
            fov_y_radians
        } else {
            core::f32::consts::PI / 4.0
        };
        let safe_aspect = if aspect_ratio.is_finite() {
            aspect_ratio
        } else {
            1.0
        };
        let clamped_fov = safe_fov.clamp(0.01, core::f32::consts::PI - 0.01);
        let half_height = (clamped_fov * 0.5).tan();
        let half_width = half_height * safe_aspect.max(0.001);
        SimpleCamera {
            origin,
            forward: safe_forward,
            right: safe_right,
            up: up_normalized,
            half_height,
            half_width,
        }
    }

    fn ray(&self, uv: Float2) -> Ray {
        let px = (2.0 * uv.x - 1.0) * self.half_width;
        let py = (1.0 - 2.0 * uv.y) * self.half_height;
        let dir = simd_normalize(self.forward + self.right * px + self.up * py);
        Ray::new(self.origin, dir)
    }
}

fn cosine_weighted_hemisphere(normal: Float3, rng: &mut Rng) -> Float3 {
    let u = rng.next_unit();
    let v = rng.next_unit();
    let phi = 2.0 * core::f32::consts::PI * u;
    let cos_theta = (1.0 - v).sqrt();
    let sin_theta = v.sqrt();
    let up = if normal.x.abs() < 0.9 {
        Float3::new(1.0, 0.0, 0.0)
    } else {
        Float3::new(0.0, 1.0, 0.0)
    };
    let tangent = simd_normalize(simd_cross(up, normal));
    let bitangent = simd_cross(normal, tangent);
    simd_normalize(
        tangent * (phi.cos() * sin_theta)
            + normal * cos_theta
            + bitangent * (phi.sin() * sin_theta),
    )
}

fn normalized_or_fallback(vector: Float3, fallback: Float3) -> Float3 {
    if !vector.x.is_finite() || !vector.y.is_finite() || !vector.z.is_finite() {
        return fallback;
    }
    let length = simd_length(vector);
    if !length.is_finite() || length <= 0.000_001 {
        return fallback;
    }
    vector / length
}

/// Re-exported for call sites that only need the dot product helper.
pub use diffuse_math::simd::simd_compat::simd_dot as point_dot;
