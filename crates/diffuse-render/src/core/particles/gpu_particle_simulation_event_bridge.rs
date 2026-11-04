//! Bridges GPU simulation events onto the CPU particle event vocabulary.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/Particles/GPUParticleSimulationEventBridge.swift`.
//! Swift writes three type extensions; the GPU-side types live in
//! `diffuse-render::core::render_stats` and the CPU-side types in
//! `diffuse-scene`, so the extensions become free functions plus extension
//! traits (Rust forbids inherent impls on foreign types).

use diffuse_scene::particles::particle_events::ParticleEvent;
use diffuse_scene::particles::particle_types::ParticleSubEmitterTrigger;

use crate::core::render_stats::{
    GPUParticleSimulationEventRecord, GPUParticleSimulationEventSnapshot,
    GPUParticleSimulationEventTrigger,
};

/// `extension GPUParticleSimulationEventTrigger`.
pub trait GPUParticleSimulationEventTriggerBridge {
    /// `var particleSubEmitterTrigger: ParticleSubEmitterTrigger?`.
    fn particle_sub_emitter_trigger(self) -> Option<ParticleSubEmitterTrigger>;
}

impl GPUParticleSimulationEventTriggerBridge for GPUParticleSimulationEventTrigger {
    fn particle_sub_emitter_trigger(self) -> Option<ParticleSubEmitterTrigger> {
        match self {
            GPUParticleSimulationEventTrigger::Collision => {
                Some(ParticleSubEmitterTrigger::Collision)
            }
            GPUParticleSimulationEventTrigger::Death => Some(ParticleSubEmitterTrigger::Death),
            GPUParticleSimulationEventTrigger::Unknown => None,
        }
    }
}

/// `extension GPUParticleSimulationEventRecord`.
pub trait GPUParticleSimulationEventRecordBridge {
    /// `func makeParticleEvent() -> ParticleEvent?`.
    fn make_particle_event(&self) -> Option<ParticleEvent>;
}

impl GPUParticleSimulationEventRecordBridge for GPUParticleSimulationEventRecord {
    fn make_particle_event(&self) -> Option<ParticleEvent> {
        let trigger = self.trigger.particle_sub_emitter_trigger()?;
        Some(ParticleEvent::new(
            trigger,
            self.position,
            self.velocity,
            self.age,
            self.lifetime,
            self.generation,
            self.appearance_index,
        ))
    }
}

/// `extension GPUParticleSimulationEventSnapshot`.
pub trait GPUParticleSimulationEventSnapshotBridge {
    /// `func makeParticleEvents() -> [ParticleEvent]`.
    fn make_particle_events(&self) -> Vec<ParticleEvent>;
}

impl GPUParticleSimulationEventSnapshotBridge for GPUParticleSimulationEventSnapshot {
    fn make_particle_events(&self) -> Vec<ParticleEvent> {
        self.records
            .iter()
            .filter_map(|record| record.make_particle_event())
            .collect()
    }
}
