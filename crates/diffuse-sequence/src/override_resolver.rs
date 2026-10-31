//! `OverrideResolver` — active shot overrides with blend weights applied.

use crate::sequence_document::{ClipEase, Shot, ShotOverride};

#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedOverride {
    pub override_value: ShotOverride,
    pub weight: f64,
}

impl ResolvedOverride {
    #[inline]
    pub fn new(override_value: ShotOverride, weight: f64) -> Self {
        ResolvedOverride {
            override_value,
            weight,
        }
    }
}

pub enum OverrideResolver {}

impl OverrideResolver {
    /// Active overrides at `sequence_frame`, in document order; callers resolve
    /// priority by consuming in order (absolute first, then additive/multiplicative).
    pub fn active_overrides(shot: &Shot, sequence_frame: i64) -> Vec<ResolvedOverride> {
        if !shot.range.contains(sequence_frame) {
            return Vec::new();
        }
        let local_position = sequence_frame - shot.range.start;
        let shot_duration = shot.range.duration();
        shot.overrides
            .iter()
            .filter_map(|shot_override| {
                let weight = Self::blend_weight(
                    local_position,
                    shot_duration,
                    shot_override.blend_in_frames,
                    shot_override.blend_out_frames,
                    shot_override.ease,
                );
                if weight > 0.0 {
                    Some(ResolvedOverride::new(shot_override.clone(), weight))
                } else {
                    None
                }
            })
            .collect()
    }

    fn blend_weight(
        local_position: i64,
        shot_duration: i64,
        blend_in: i64,
        blend_out: i64,
        ease: ClipEase,
    ) -> f64 {
        let mut weight: f64 = 1.0;
        if blend_in > 0 {
            let t = (local_position as f64 / blend_in as f64).clamp(0.0, 1.0);
            weight = weight.min(Self::apply_ease(t, ease));
        }
        if blend_out > 0 {
            let remaining = (shot_duration - local_position).max(0);
            let t = (remaining as f64 / blend_out as f64).clamp(0.0, 1.0);
            weight = weight.min(Self::apply_ease(t, ease));
        }
        weight
    }

    fn apply_ease(t: f64, ease: ClipEase) -> f64 {
        match ease {
            ClipEase::Linear => t,
            ClipEase::EaseIn => t * t,
            ClipEase::EaseOut => 1.0 - (1.0 - t) * (1.0 - t),
            ClipEase::EaseInOut => {
                if t < 0.5 {
                    2.0 * t * t
                } else {
                    1.0 - 2.0 * (1.0 - t) * (1.0 - t)
                }
            }
            ClipEase::Step => {
                if t >= 1.0 {
                    1.0
                } else {
                    0.0
                }
            }
        }
    }
}
