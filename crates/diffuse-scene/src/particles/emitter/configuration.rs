//! Module-stack configuration entry point.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/Emitter/Configuration.swift`.

use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::emitter::particle_emitter_settings::ParticleEmitterSettings;
use crate::particles::particle_modules::ParticleModuleStack;

impl ParticleEmitter {
    /// Creates a fresh simulation from the existing, domain-grouped authoring
    /// modules. Disabled modules retain the emitter's defaults.
    pub fn from_module_stack(module_stack: &ParticleModuleStack) -> Self {
        let mut emitter = ParticleEmitter::new(ParticleEmitterSettings::new());
        emitter.apply(module_stack.clone());
        emitter
    }
}
