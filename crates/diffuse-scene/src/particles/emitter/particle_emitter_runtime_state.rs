//! Transient CPU simulation data for one emitter.
//!
//! Ported from
//! `Engine/Sources/SceneRuntime/Particles/Emitter/ParticleEmitterRuntimeState.swift`.
//!
//! Authoring configuration survives a [`ParticleEmitterRuntimeState::clear`]; all
//! timing, live pools and feedback are reset together, preserving the PRNG.

use diffuse_math::simd::simd_compat::Float3;

use crate::particles::particle_events::ParticleEvent;
use crate::particles::particle_stats::ParticleEmitterFrameStats;
use crate::particles::particle_types::Particle;

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ParticleEmitterRuntimeState {
    pub(crate) particles: Vec<Particle>,
    pub(crate) last_frame_spawned_particles: Vec<Particle>,
    pub(crate) last_frame_events: Vec<ParticleEvent>,
    pub(crate) last_frame_stats: ParticleEmitterFrameStats,
    pub(crate) emitter_age: f32,
    pub(crate) emission_accumulator: f32,
    pub(crate) distance_emission_accumulator: f32,
    pub(crate) burst_accumulator: f32,
    pub(crate) burst_spawn_accumulator: f32,
    pub(crate) previous_emitter_position: Option<Float3>,
    pub(crate) has_prewarmed: bool,
    pub(crate) rng_state: u64,
}

impl ParticleEmitterRuntimeState {
    /// The Swift memberwise initializer's defaults, including the fixed PRNG seed.
    pub(crate) fn new() -> Self {
        ParticleEmitterRuntimeState {
            particles: Vec::new(),
            last_frame_spawned_particles: Vec::new(),
            last_frame_events: Vec::new(),
            last_frame_stats: ParticleEmitterFrameStats::empty(),
            emitter_age: 0.0,
            emission_accumulator: 0.0,
            distance_emission_accumulator: 0.0,
            burst_accumulator: 0.0,
            burst_spawn_accumulator: 0.0,
            previous_emitter_position: None,
            has_prewarmed: false,
            rng_state: 0x9E37_79B9,
        }
    }

    /// `init(rngState:)` — every other stored property keeps its default.
    pub(crate) fn with_rng_state(rng_state: u64) -> Self {
        let mut state = ParticleEmitterRuntimeState::new();
        state.rng_state = rng_state;
        state
    }

    /// `removeAll(keepingCapacity:)` keeps the backing allocation, so `Vec::clear`
    /// matches the Swift behavior exactly.
    pub(crate) fn clear(&mut self) {
        self.particles.clear();
        self.last_frame_spawned_particles.clear();
        self.last_frame_events.clear();
        self.last_frame_stats = ParticleEmitterFrameStats::empty();
        self.emitter_age = 0.0;
        self.emission_accumulator = 0.0;
        self.distance_emission_accumulator = 0.0;
        self.burst_accumulator = 0.0;
        self.burst_spawn_accumulator = 0.0;
        self.previous_emitter_position = None;
        self.has_prewarmed = false;
        // The PRNG state is intentionally preserved.
    }
}

impl Default for ParticleEmitterRuntimeState {
    fn default() -> Self {
        ParticleEmitterRuntimeState::new()
    }
}
