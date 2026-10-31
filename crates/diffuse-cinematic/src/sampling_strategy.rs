//! `SamplingStrategy` implementations.

use diffuse_math::simd::simd_compat::Float2;

/// A 2D sample point source.
pub trait SamplingStrategy: Send {
    fn sample2d(&self, index: usize, sample: usize) -> Float2;
    fn name(&self) -> &'static str;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct HaltonSampler;

impl SamplingStrategy for HaltonSampler {
    fn sample2d(&self, index: usize, _sample: usize) -> Float2 {
        Float2::new(halton(index, 2), halton(index, 3))
    }

    fn name(&self) -> &'static str {
        "halton"
    }
}

/// Radical-inverse in `base`. Swift used `Int` arithmetic; the index and base are
/// non-negative, so `usize` keeps the same results.
fn halton(index: usize, base: usize) -> f32 {
    let mut result: f32 = 0.0;
    let mut f: f32 = 1.0;
    let mut i = index + 1;
    while i > 0 {
        f /= base as f32;
        result += f * (i % base) as f32;
        i /= base;
    }
    result
}

#[derive(Clone, Copy, Debug)]
pub struct BlueNoiseSampler {
    pub texture_size: usize,
}

impl BlueNoiseSampler {
    /// Swift default: `textureSize: 64`.
    #[inline]
    pub fn new(texture_size: usize) -> Self {
        BlueNoiseSampler { texture_size }
    }
}

impl Default for BlueNoiseSampler {
    fn default() -> Self {
        BlueNoiseSampler { texture_size: 64 }
    }
}

impl SamplingStrategy for BlueNoiseSampler {
    fn sample2d(&self, index: usize, sample: usize) -> Float2 {
        // Scrambled Sobol-style fallback; replace with a precomputed blue-noise
        // texture lookup when one is available.
        let x = ((index.wrapping_mul(2_654_435_761)) & 0xFF) as f32 / 256.0;
        let y = ((sample.wrapping_mul(2_654_435_761)) & 0xFF) as f32 / 256.0;
        Float2::new(x, y)
    }

    fn name(&self) -> &'static str {
        "blue_noise"
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SamplingStrategyPreset {
    Halton,
    BlueNoise,
}

impl SamplingStrategyPreset {
    /// Swift's `CaseIterable` order.
    pub const ALL: [SamplingStrategyPreset; 2] = [
        SamplingStrategyPreset::Halton,
        SamplingStrategyPreset::BlueNoise,
    ];

    pub fn create(self) -> Box<dyn SamplingStrategy> {
        match self {
            SamplingStrategyPreset::Halton => Box::new(HaltonSampler),
            SamplingStrategyPreset::BlueNoise => Box::new(BlueNoiseSampler::default()),
        }
    }
}
