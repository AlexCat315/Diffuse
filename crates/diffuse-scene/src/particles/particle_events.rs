//! Particle events emitted for sub-emitter triggers, and sub-emitter rules.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/ParticleEvents.swift`.

use diffuse_math::simd::simd_compat::{Float3, Float4, simd_clamp_scalar};
use serde::{Deserialize, Serialize};

use crate::particles::particle_types::{Particle, ParticleSubEmitterTrigger};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ParticleEvent {
    pub trigger: ParticleSubEmitterTrigger,
    pub position: Float3,
    pub velocity: Float3,
    pub age: f32,
    pub lifetime: f32,
    pub generation: u8,
    pub appearance_index: u16,
}

impl ParticleEvent {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        trigger: ParticleSubEmitterTrigger,
        position: Float3,
        velocity: Float3,
        age: f32,
        lifetime: f32,
        generation: u8,
        appearance_index: u16,
    ) -> Self {
        ParticleEvent {
            trigger,
            position,
            velocity,
            age: age.max(0.0),
            lifetime: lifetime.max(0.0),
            generation,
            appearance_index,
        }
    }

    /// `init(trigger:source:)`.
    pub fn from_particle(trigger: ParticleSubEmitterTrigger, source: &Particle) -> Self {
        ParticleEvent::new(
            trigger,
            source.position,
            source.velocity,
            source.age,
            source.lifetime,
            source.generation,
            source.appearance_index,
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParticleSubEmitter {
    pub trigger: ParticleSubEmitterTrigger,
    pub burst_count: i64,
    pub probability: f32,
    pub max_depth: i64,
    pub inherit_velocity: f32,
    pub lifetime: f32,
    pub start_velocity: Float3,
    pub velocity_randomness: Float3,
    pub start_size: f32,
    pub end_size: f32,
    pub start_color: Float4,
    pub end_color: Float4,
}

impl ParticleSubEmitter {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        trigger: ParticleSubEmitterTrigger,
        burst_count: i64,
        probability: f32,
        max_depth: i64,
        inherit_velocity: f32,
        lifetime: f32,
        start_velocity: Float3,
        velocity_randomness: Float3,
        start_size: f32,
        end_size: f32,
        start_color: Float4,
        end_color: Float4,
    ) -> Self {
        ParticleSubEmitter {
            trigger,
            burst_count: burst_count.max(0),
            probability: simd_clamp_scalar(probability, 0.0, 1.0),
            max_depth: max_depth.max(0),
            inherit_velocity: inherit_velocity.max(0.0),
            lifetime: lifetime.max(0.0001),
            start_velocity,
            velocity_randomness,
            start_size: start_size.max(0.0),
            end_size: end_size.max(0.0),
            start_color,
            end_color,
        }
    }

    pub fn is_active(&self) -> bool {
        self.trigger != ParticleSubEmitterTrigger::None
            && self.burst_count > 0
            && self.probability > 0.0
            && self.max_depth > 0
    }
}

impl Default for ParticleSubEmitter {
    /// Swift's default argument values, run through the clamping initializer.
    fn default() -> Self {
        ParticleSubEmitter::new(
            ParticleSubEmitterTrigger::None,
            0,
            1.0,
            1,
            0.0,
            0.5,
            Float3::ZERO,
            Float3::ZERO,
            0.25,
            0.0,
            Float4::new(1.0, 1.0, 1.0, 1.0),
            Float4::new(1.0, 1.0, 1.0, 0.0),
        )
    }
}
