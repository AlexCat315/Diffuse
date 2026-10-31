//! Particle appearance: texture-sheet frame selection and per-step size/colour.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/Emitter/Appearance.swift`.

use diffuse_math::simd::simd_compat::Float4;

use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::particle_types::{Particle, ParticleTextureSheetPlaybackMode};

/// The appearance a particle interpolates between over its lifetime.
struct ParticleAppearance {
    start_size: f32,
    end_size: f32,
    start_color: Float4,
    end_color: Float4,
}

impl ParticleEmitter {
    /// UV rect for a particle's current texture sheet frame: x, y, width, height.
    pub fn texture_uv_rect(&self, particle: &Particle) -> Float4 {
        let columns = self.settings.texture_sheet.columns.max(1);
        let rows = self.settings.texture_sheet.rows.max(1);
        let max_frames = (columns * rows).max(1);
        let frame_index = self.texture_sheet_frame_index_with_max(particle, max_frames);
        let column = frame_index % columns;
        let row = frame_index / columns;
        let width = 1.0 / columns as f32;
        let height = 1.0 / rows as f32;
        Float4::new(
            column as f32 * width,
            row as f32 * height,
            width,
            height,
        )
    }

    pub fn texture_sheet_frame_index(&self, particle: &Particle) -> i64 {
        let columns = self.settings.texture_sheet.columns.max(1);
        let rows = self.settings.texture_sheet.rows.max(1);
        self.texture_sheet_frame_index_with_max(particle, (columns * rows).max(1))
    }

    /// `textureSheetFrameIndex(for:maxFrames:)`, private in Swift because it is only
    /// reachable through the two overloads above.
    pub(crate) fn texture_sheet_frame_index_with_max(
        &self,
        particle: &Particle,
        max_frames: i64,
    ) -> i64 {
        let sheet = &self.settings.texture_sheet;
        let safe_max_frames = max_frames.max(1);
        let start_frame = sheet.start_frame.max(0).min(safe_max_frames - 1);
        let safe_frame_count = sheet
            .frame_count
            .max(1)
            .min(safe_max_frames - start_frame);
        let random_range = sheet.frame_randomness.min(safe_frame_count - 1).max(0);
        let random_offset = if random_range > 0 {
            // Swift's `UInt16(randomRange + 1)` traps when the range does not fit;
            // `try_from` keeps that trap instead of silently truncating.
            let modulus =
                u16::try_from(random_range + 1).expect("frame randomness exceeds UInt16 range");
            i64::from(particle.texture_frame_seed % modulus)
        } else {
            0
        };
        let first_frame = (safe_frame_count - 1).min(random_offset);

        let advanced_frame: i64 = match sheet.playback_mode {
            ParticleTextureSheetPlaybackMode::Automatic => {
                if sheet.frame_rate > 0.0 {
                    (swift_max_f32(0.0, particle.age) * sheet.frame_rate).floor() as i64
                } else {
                    (particle.normalized_age() * safe_frame_count as f32).floor() as i64
                }
            }
            ParticleTextureSheetPlaybackMode::Lifetime => {
                (particle.normalized_age() * safe_frame_count as f32).floor() as i64
            }
            ParticleTextureSheetPlaybackMode::PlayOnce => {
                let rate = if sheet.frame_rate > 0.0 {
                    sheet.frame_rate
                } else {
                    safe_frame_count as f32
                };
                (swift_max_f32(0.0, particle.age) * rate).floor() as i64
            }
            ParticleTextureSheetPlaybackMode::Loop => {
                let rate = if sheet.frame_rate > 0.0 {
                    sheet.frame_rate
                } else {
                    safe_frame_count as f32
                };
                ((swift_max_f32(0.0, particle.age) * rate).floor() as i64) % safe_frame_count
            }
            ParticleTextureSheetPlaybackMode::SingleFrame => 0,
        };

        match sheet.playback_mode {
            ParticleTextureSheetPlaybackMode::Loop => {
                start_frame + ((first_frame + advanced_frame.max(0)) % safe_frame_count)
            }
            ParticleTextureSheetPlaybackMode::SingleFrame => start_frame + first_frame,
            ParticleTextureSheetPlaybackMode::Automatic
            | ParticleTextureSheetPlaybackMode::Lifetime
            | ParticleTextureSheetPlaybackMode::PlayOnce => {
                start_frame
                    + (safe_frame_count - 1).min(first_frame + advanced_frame.max(0))
            }
        }
    }

    /// Re-derives `size` and `color` from the particle's normalized age.
    pub(crate) fn refresh_appearance(&self, p: &mut Particle) {
        let t = p.normalized_age();
        let size_t = self.settings.appearance.size_curve.evaluate(t);
        let color_t = self.settings.appearance.color_curve.evaluate(t);
        let appearance = self.appearance_for(p);
        p.size = (appearance.start_size
            + (appearance.end_size - appearance.start_size) * size_t)
            * p.size_scale;
        p.color = appearance.start_color + (appearance.end_color - appearance.start_color) * color_t;
    }

    fn appearance_for(&self, particle: &Particle) -> ParticleAppearance {
        if particle.appearance_index == 0 {
            return ParticleAppearance {
                start_size: self.settings.appearance.start_size,
                end_size: self.settings.appearance.end_size,
                start_color: self.settings.appearance.start_color,
                end_color: self.settings.appearance.end_color,
            };
        }
        if particle.appearance_index == 1 {
            return ParticleAppearance {
                start_size: self.settings.sub_emitters.legacy_start_size,
                end_size: self.settings.sub_emitters.legacy_end_size,
                start_color: self.settings.sub_emitters.legacy_start_color,
                end_color: self.settings.sub_emitters.legacy_end_color,
            };
        }
        let rule_index = i64::from(particle.appearance_index) - 2;
        if rule_index >= 0 && (rule_index as usize) < self.settings.sub_emitters.rules.len() {
            let rule = &self.settings.sub_emitters.rules[rule_index as usize];
            return ParticleAppearance {
                start_size: rule.start_size,
                end_size: rule.end_size,
                start_color: rule.start_color,
                end_color: rule.end_color,
            };
        }
        ParticleAppearance {
            start_size: self.settings.sub_emitters.legacy_start_size,
            end_size: self.settings.sub_emitters.legacy_end_size,
            start_color: self.settings.sub_emitters.legacy_start_color,
            end_color: self.settings.sub_emitters.legacy_end_color,
        }
    }

    /// `UInt16(truncatingIfNeeded: rngState ^ (rngState >> 32))`.
    pub(crate) fn texture_frame_seed_snapshot(&self) -> u16 {
        (self.runtime.rng_state ^ (self.runtime.rng_state >> 32)) as u16
    }
}

/// Swift's `max(_:_:)` is `y >= x ? y : x`, so a NaN first operand survives.
#[inline]
fn swift_max_f32(x: f32, y: f32) -> f32 {
    if y >= x { y } else { x }
}
