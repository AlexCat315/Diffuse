//! Particle authoring settings and an independent, seeded simulation pool.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/Emitter/ParticleEmitter.swift`.

use crate::entity_id::RuntimeComponent;
use crate::particles::emitter::particle_emitter_runtime_state::ParticleEmitterRuntimeState;
use crate::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
use crate::particles::particle_events::ParticleEvent;
use crate::particles::particle_modules::ParticleModuleStack;
use crate::particles::particle_stats::ParticleEmitterFrameStats;
use crate::particles::particle_types::Particle;

#[derive(Clone, Debug, PartialEq)]
pub struct ParticleEmitter {
    pub settings: ParticleEmitterSettings,
    /// Editor ordering and enabled states; simulation reads the typed settings.
    pub authored_module_stack: Option<ParticleModuleStack>,
    pub(crate) runtime: ParticleEmitterRuntimeState,
}

impl ParticleEmitter {
    pub fn new(settings: ParticleEmitterSettings) -> Self {
        let mut settings = settings;
        settings.normalize();
        let runtime = ParticleEmitterRuntimeState::with_rng_state(settings.emission.seed);
        ParticleEmitter {
            settings,
            authored_module_stack: None,
            runtime,
        }
    }

    pub fn particles(&self) -> &[Particle] {
        &self.runtime.particles
    }

    pub fn last_frame_spawned_particles(&self) -> &[Particle] {
        &self.runtime.last_frame_spawned_particles
    }

    pub fn last_frame_events(&self) -> &[ParticleEvent] {
        &self.runtime.last_frame_events
    }

    pub fn last_frame_stats(&self) -> ParticleEmitterFrameStats {
        self.runtime.last_frame_stats
    }
}

impl Default for ParticleEmitter {
    fn default() -> Self {
        ParticleEmitter::new(ParticleEmitterSettings::default())
    }
}

impl RuntimeComponent for ParticleEmitter {}
