//! Authored particle settings, grouped by the feature that owns their defaults
//! and validation.
//!
//! Ported from
//! `Engine/Sources/SceneRuntime/Particles/Emitter/ParticleEmitterSettings.swift`.
//!
//! Decoding mirrors Swift's `decodeIfPresent(...) ?? <default>`: every key is
//! optional and falls back to the property's default, which serde's
//! container-level `default` reproduces. Keys are camelCase (`textureSheet`,
//! `subEmitters`, `gpuSimulation`).

use serde::{Deserialize, Serialize};

use crate::particles::particle_modules::{
    ParticleAppearanceModule, ParticleCollisionModule, ParticleEmissionModule,
    ParticleForcesModule, ParticleGPUSimulationModule, ParticleRendererModule,
    ParticleShapeModule, ParticleSubEmittersModule, ParticleTextureSheetModule,
    ParticleTrailsModule, ParticleVelocityModule,
};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ParticleEmitterSettings {
    pub emission: ParticleEmissionModule,
    pub shape: ParticleShapeModule,
    pub velocity: ParticleVelocityModule,
    pub forces: ParticleForcesModule,
    pub collision: ParticleCollisionModule,
    pub appearance: ParticleAppearanceModule,
    pub texture_sheet: ParticleTextureSheetModule,
    pub renderer: ParticleRendererModule,
    pub trails: ParticleTrailsModule,
    pub sub_emitters: ParticleSubEmittersModule,
    pub gpu_simulation: ParticleGPUSimulationModule,
}

impl ParticleEmitterSettings {
    /// Swift's defaulted `init(_ configure:)` with no configuration closure.
    pub fn new() -> Self {
        ParticleEmitterSettings::default()
    }

    pub(crate) fn normalize(&mut self) {
        self.emission.normalize();
        self.shape.normalize();
        self.velocity.normalize();
        self.forces.normalize();
        self.collision.normalize();
        self.appearance.normalize();
        self.texture_sheet.normalize();
        self.renderer.normalize();
        self.trails.normalize();
        self.sub_emitters.normalize();
        self.gpu_simulation.normalize();
    }
}
