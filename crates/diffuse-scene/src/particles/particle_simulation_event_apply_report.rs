//! Result of applying GPU-readback particle simulation events to scene emitters.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/ParticleSimulationEventApplyReport.swift`.

use std::collections::BTreeMap;

use crate::particles::particle_stats::ParticleEmitterFrameStats;

#[derive(Clone, Debug, PartialEq)]
pub struct ParticleSimulationEventApplyReport {
    pub requested_emitter_count: i64,
    pub applied_emitter_count: i64,
    pub missing_emitter_count: i64,
    pub empty_event_emitter_count: i64,
    pub event_count: i64,
    pub applied_event_count: i64,
    pub total_readback_event_count: i64,
    pub dropped_readback_event_count: i64,
    pub collision_event_count: i64,
    pub death_event_count: i64,
    pub sub_emitter_spawned_count: i64,
    pub spawned_particle_count: i64,
    pub gpu_alive_particle_count: i64,
    pub gpu_expired_particle_count: i64,
    pub gpu_collision_event_count: i64,
    pub gpu_spawned_particle_count: i64,
    pub gpu_dropped_spawn_count: i64,
    pub gpu_compacted_particle_count: i64,
    pub requested_spawn_count: i64,
    pub spawn_budget_limit: i64,
    pub spawn_budget_consumed_count: i64,
    pub capacity_limited_spawn_count: i64,
    pub spawn_budget_limited_count: i64,
    pub emitter_stats_by_entity: BTreeMap<u64, ParticleEmitterFrameStats>,
}

impl ParticleSimulationEventApplyReport {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        requested_emitter_count: i64,
        applied_emitter_count: i64,
        missing_emitter_count: i64,
        empty_event_emitter_count: i64,
        event_count: i64,
        applied_event_count: i64,
        total_readback_event_count: i64,
        dropped_readback_event_count: i64,
        collision_event_count: i64,
        death_event_count: i64,
        sub_emitter_spawned_count: i64,
        spawned_particle_count: i64,
        gpu_alive_particle_count: i64,
        gpu_expired_particle_count: i64,
        gpu_collision_event_count: i64,
        gpu_spawned_particle_count: i64,
        gpu_dropped_spawn_count: i64,
        gpu_compacted_particle_count: i64,
        requested_spawn_count: i64,
        spawn_budget_limit: i64,
        spawn_budget_consumed_count: i64,
        capacity_limited_spawn_count: i64,
        spawn_budget_limited_count: i64,
        emitter_stats_by_entity: BTreeMap<u64, ParticleEmitterFrameStats>,
    ) -> Self {
        ParticleSimulationEventApplyReport {
            requested_emitter_count: requested_emitter_count.max(0),
            applied_emitter_count: applied_emitter_count.max(0),
            missing_emitter_count: missing_emitter_count.max(0),
            empty_event_emitter_count: empty_event_emitter_count.max(0),
            event_count: event_count.max(0),
            applied_event_count: applied_event_count.max(0),
            total_readback_event_count: total_readback_event_count.max(0),
            dropped_readback_event_count: dropped_readback_event_count.max(0),
            collision_event_count: collision_event_count.max(0),
            death_event_count: death_event_count.max(0),
            sub_emitter_spawned_count: sub_emitter_spawned_count.max(0),
            spawned_particle_count: spawned_particle_count.max(0),
            gpu_alive_particle_count: gpu_alive_particle_count.max(0),
            gpu_expired_particle_count: gpu_expired_particle_count.max(0),
            gpu_collision_event_count: gpu_collision_event_count.max(0),
            gpu_spawned_particle_count: gpu_spawned_particle_count.max(0),
            gpu_dropped_spawn_count: gpu_dropped_spawn_count.max(0),
            gpu_compacted_particle_count: gpu_compacted_particle_count.max(0),
            requested_spawn_count: requested_spawn_count.max(0),
            spawn_budget_limit: spawn_budget_limit.max(0),
            spawn_budget_consumed_count: spawn_budget_consumed_count.max(0),
            capacity_limited_spawn_count: capacity_limited_spawn_count.max(0),
            spawn_budget_limited_count: spawn_budget_limited_count.max(0),
            emitter_stats_by_entity,
        }
    }

    pub fn empty() -> Self {
        ParticleSimulationEventApplyReport::default()
    }

    pub fn emitter_stats_for(&self, raw_entity_id: Option<u64>) -> Option<ParticleEmitterFrameStats> {
        raw_entity_id.and_then(|raw| self.emitter_stats_by_entity.get(&raw).copied())
    }

    pub fn dropped_spawn_count(&self) -> i64 {
        self.capacity_limited_spawn_count
            + self.spawn_budget_limited_count
            + self.gpu_dropped_spawn_count
    }

    pub fn spawn_budget_utilization(&self) -> f32 {
        if self.spawn_budget_limit <= 0 {
            return 0.0;
        }
        self.spawn_budget_consumed_count.min(self.spawn_budget_limit) as f32
            / self.spawn_budget_limit as f32
    }
}

impl Default for ParticleSimulationEventApplyReport {
    fn default() -> Self {
        ParticleSimulationEventApplyReport::new(
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            BTreeMap::new(),
        )
    }
}
