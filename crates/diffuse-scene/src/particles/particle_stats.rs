//! Per-emitter and per-frame particle statistics.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/ParticleStats.swift`.

use std::collections::BTreeMap;

use crate::particles::particle_scalability::{
    ParticleRuntimePressureLevel, dominant_particle_runtime_pressure_level,
};
use crate::particles::particle_simulation_event_apply_report::ParticleSimulationEventApplyReport;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ParticleEmitterFrameStats {
    pub simulated_delta_time: f32,
    pub starting_live_particle_count: i64,
    pub live_particle_count: i64,
    pub max_particle_count: i64,
    pub live_particle_limit: i64,
    pub continuous_spawned_count: i64,
    pub burst_spawned_count: i64,
    pub distance_spawned_count: i64,
    pub sub_emitter_spawned_count: i64,
    pub expired_particle_count: i64,
    pub collision_count: i64,
    pub requested_spawn_count: i64,
    pub spawn_budget_limit: i64,
    pub spawn_budget_consumed_count: i64,
    pub capacity_limited_spawn_count: i64,
    pub spawn_budget_limited_count: i64,
}

impl ParticleEmitterFrameStats {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        simulated_delta_time: f32,
        starting_live_particle_count: i64,
        live_particle_count: i64,
        max_particle_count: i64,
        live_particle_limit: i64,
        continuous_spawned_count: i64,
        burst_spawned_count: i64,
        distance_spawned_count: i64,
        sub_emitter_spawned_count: i64,
        expired_particle_count: i64,
        collision_count: i64,
        requested_spawn_count: i64,
        spawn_budget_limit: i64,
        spawn_budget_consumed_count: i64,
        capacity_limited_spawn_count: i64,
        spawn_budget_limited_count: i64,
    ) -> Self {
        ParticleEmitterFrameStats {
            simulated_delta_time: simulated_delta_time.max(0.0),
            starting_live_particle_count: starting_live_particle_count.max(0),
            live_particle_count: live_particle_count.max(0),
            max_particle_count: max_particle_count.max(0),
            live_particle_limit: live_particle_limit.max(0),
            continuous_spawned_count: continuous_spawned_count.max(0),
            burst_spawned_count: burst_spawned_count.max(0),
            distance_spawned_count: distance_spawned_count.max(0),
            sub_emitter_spawned_count: sub_emitter_spawned_count.max(0),
            expired_particle_count: expired_particle_count.max(0),
            collision_count: collision_count.max(0),
            requested_spawn_count: requested_spawn_count.max(0),
            spawn_budget_limit: spawn_budget_limit.max(0),
            spawn_budget_consumed_count: spawn_budget_consumed_count.max(0),
            capacity_limited_spawn_count: capacity_limited_spawn_count.max(0),
            spawn_budget_limited_count: spawn_budget_limited_count.max(0),
        }
    }

    pub fn empty() -> Self {
        ParticleEmitterFrameStats::default()
    }

    pub fn spawned_particle_count(&self) -> i64 {
        self.continuous_spawned_count
            + self.burst_spawned_count
            + self.distance_spawned_count
            + self.sub_emitter_spawned_count
    }

    pub fn live_particle_budget_limit(&self) -> i64 {
        if self.live_particle_limit > 0 {
            self.live_particle_limit
        } else {
            self.max_particle_count
        }
    }

    pub fn live_particle_budget_utilization(&self) -> f32 {
        if self.live_particle_budget_limit() <= 0 {
            return 0.0;
        }
        self.live_particle_count as f32 / self.live_particle_budget_limit() as f32
    }

    pub fn dropped_spawn_count(&self) -> i64 {
        self.capacity_limited_spawn_count + self.spawn_budget_limited_count
    }

    pub fn spawn_budget_utilization(&self) -> f32 {
        if self.spawn_budget_limit <= 0 {
            return 0.0;
        }
        self.spawn_budget_consumed_count.min(self.spawn_budget_limit) as f32
            / self.spawn_budget_limit as f32
    }

    pub fn runtime_pressure_level(&self) -> ParticleRuntimePressureLevel {
        if self.dropped_spawn_count() > 0 || self.live_particle_budget_utilization() >= 1.0 {
            return ParticleRuntimePressureLevel::Critical;
        }
        if self.live_particle_budget_utilization() >= 0.9 {
            return ParticleRuntimePressureLevel::Warning;
        }
        if self.live_particle_count > 0 || self.spawned_particle_count() > 0 {
            return ParticleRuntimePressureLevel::Nominal;
        }
        ParticleRuntimePressureLevel::Idle
    }
}

impl Default for ParticleEmitterFrameStats {
    fn default() -> Self {
        ParticleEmitterFrameStats::new(0.0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ParticleFrameStatsResource {
    pub simulated_delta_time: f32,
    pub emitter_stats_by_entity: BTreeMap<u64, ParticleEmitterFrameStats>,
    pub emitter_count: i64,
    pub active_emitter_count: i64,
    pub live_particle_count: i64,
    pub max_particle_count: i64,
    pub live_particle_limit: i64,
    pub live_particle_budget_limit: i64,
    pub spawned_particle_count: i64,
    pub continuous_spawned_count: i64,
    pub burst_spawned_count: i64,
    pub distance_spawned_count: i64,
    pub sub_emitter_spawned_count: i64,
    pub expired_particle_count: i64,
    pub collision_count: i64,
    pub requested_spawn_count: i64,
    pub spawn_budget_limit: i64,
    pub spawn_budget_consumed_count: i64,
    pub capacity_limited_spawn_count: i64,
    pub spawn_budget_limited_count: i64,
    pub gpu_alive_particle_count: i64,
    pub gpu_expired_particle_count: i64,
    pub gpu_collision_event_count: i64,
    pub gpu_spawned_particle_count: i64,
    pub gpu_dropped_spawn_count: i64,
    pub gpu_compacted_particle_count: i64,
    pub runtime_pressure_level: ParticleRuntimePressureLevel,
}

impl ParticleFrameStatsResource {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        simulated_delta_time: f32,
        emitter_stats: Vec<ParticleEmitterFrameStats>,
        emitter_stats_by_entity: BTreeMap<u64, ParticleEmitterFrameStats>,
        gpu_alive_particle_count: i64,
        gpu_expired_particle_count: i64,
        gpu_collision_event_count: i64,
        gpu_spawned_particle_count: i64,
        gpu_dropped_spawn_count: i64,
        gpu_compacted_particle_count: i64,
    ) -> Self {
        let emitter_count = emitter_stats.len() as i64;
        let active_emitter_count = emitter_stats
            .iter()
            .filter(|stats| {
                stats.live_particle_count > 0
                    || stats.spawned_particle_count() > 0
                    || stats.requested_spawn_count > 0
            })
            .count() as i64;
        let live_particle_count = emitter_stats
            .iter()
            .map(|stats| stats.live_particle_count)
            .sum();
        let max_particle_count = emitter_stats
            .iter()
            .map(|stats| stats.max_particle_count)
            .sum();
        let live_particle_limit = emitter_stats
            .iter()
            .map(|stats| stats.live_particle_limit)
            .sum();
        let live_particle_budget_limit = emitter_stats
            .iter()
            .map(|stats| stats.live_particle_budget_limit())
            .sum();
        let spawned_particle_count = emitter_stats
            .iter()
            .map(|stats| stats.spawned_particle_count())
            .sum();
        let continuous_spawned_count = emitter_stats
            .iter()
            .map(|stats| stats.continuous_spawned_count)
            .sum();
        let burst_spawned_count = emitter_stats
            .iter()
            .map(|stats| stats.burst_spawned_count)
            .sum();
        let distance_spawned_count = emitter_stats
            .iter()
            .map(|stats| stats.distance_spawned_count)
            .sum();
        let sub_emitter_spawned_count = emitter_stats
            .iter()
            .map(|stats| stats.sub_emitter_spawned_count)
            .sum();
        let expired_particle_count = emitter_stats
            .iter()
            .map(|stats| stats.expired_particle_count)
            .sum();
        let collision_count = emitter_stats
            .iter()
            .map(|stats| stats.collision_count)
            .sum();
        let requested_spawn_count = emitter_stats
            .iter()
            .map(|stats| stats.requested_spawn_count)
            .sum();
        let spawn_budget_limit = emitter_stats
            .iter()
            .map(|stats| stats.spawn_budget_limit)
            .sum();
        let spawn_budget_consumed_count = emitter_stats
            .iter()
            .map(|stats| stats.spawn_budget_consumed_count)
            .sum();
        let capacity_limited_spawn_count = emitter_stats
            .iter()
            .map(|stats| stats.capacity_limited_spawn_count)
            .sum();
        let spawn_budget_limited_count = emitter_stats
            .iter()
            .map(|stats| stats.spawn_budget_limited_count)
            .sum();
        let gpu_alive_particle_count = gpu_alive_particle_count.max(0);
        let gpu_expired_particle_count = gpu_expired_particle_count.max(0);
        let gpu_collision_event_count = gpu_collision_event_count.max(0);
        let gpu_spawned_particle_count = gpu_spawned_particle_count.max(0);
        let gpu_dropped_spawn_count = gpu_dropped_spawn_count.max(0);
        let gpu_compacted_particle_count = gpu_compacted_particle_count.max(0);
        let emitter_pressure = emitter_stats.iter().fold(
            ParticleRuntimePressureLevel::Idle,
            |dominant, stats| {
                dominant_particle_runtime_pressure_level(dominant, stats.runtime_pressure_level())
            },
        );
        let runtime_pressure_level = dominant_particle_runtime_pressure_level(
            emitter_pressure,
            Self::gpu_runtime_pressure_level(
                gpu_alive_particle_count,
                gpu_dropped_spawn_count,
                live_particle_budget_limit,
            ),
        );
        ParticleFrameStatsResource {
            simulated_delta_time: simulated_delta_time.max(0.0),
            emitter_stats_by_entity,
            emitter_count,
            active_emitter_count,
            live_particle_count,
            max_particle_count,
            live_particle_limit,
            live_particle_budget_limit,
            spawned_particle_count,
            continuous_spawned_count,
            burst_spawned_count,
            distance_spawned_count,
            sub_emitter_spawned_count,
            expired_particle_count,
            collision_count,
            requested_spawn_count,
            spawn_budget_limit,
            spawn_budget_consumed_count,
            capacity_limited_spawn_count,
            spawn_budget_limited_count,
            gpu_alive_particle_count,
            gpu_expired_particle_count,
            gpu_collision_event_count,
            gpu_spawned_particle_count,
            gpu_dropped_spawn_count,
            gpu_compacted_particle_count,
            runtime_pressure_level,
        }
    }

    pub fn empty() -> Self {
        ParticleFrameStatsResource::default()
    }

    pub fn emitter_stats_for(&self, raw_entity_id: Option<u64>) -> Option<ParticleEmitterFrameStats> {
        raw_entity_id.and_then(|raw| self.emitter_stats_by_entity.get(&raw).copied())
    }

    pub fn live_particle_budget_utilization(&self) -> f32 {
        if self.live_particle_budget_limit <= 0 {
            return 0.0;
        }
        self.live_particle_count as f32 / self.live_particle_budget_limit as f32
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

    pub fn merging_gpu_readback(
        &self,
        report: &ParticleSimulationEventApplyReport,
    ) -> ParticleFrameStatsResource {
        let mut stats = self.clone();
        stats.gpu_alive_particle_count = report.gpu_alive_particle_count;
        stats.gpu_expired_particle_count = report.gpu_expired_particle_count;
        stats.gpu_collision_event_count = report.gpu_collision_event_count;
        stats.gpu_spawned_particle_count = report.gpu_spawned_particle_count;
        stats.gpu_dropped_spawn_count = report.gpu_dropped_spawn_count;
        stats.gpu_compacted_particle_count = report.gpu_compacted_particle_count;
        stats.runtime_pressure_level = dominant_particle_runtime_pressure_level(
            stats.runtime_pressure_level,
            Self::gpu_runtime_pressure_level(
                stats.gpu_alive_particle_count,
                stats.gpu_dropped_spawn_count,
                stats.live_particle_budget_limit,
            ),
        );
        stats
    }

    fn gpu_runtime_pressure_level(
        gpu_alive_particle_count: i64,
        gpu_dropped_spawn_count: i64,
        live_particle_budget_limit: i64,
    ) -> ParticleRuntimePressureLevel {
        if gpu_dropped_spawn_count > 0 {
            return ParticleRuntimePressureLevel::Critical;
        }
        if live_particle_budget_limit > 0 && gpu_alive_particle_count >= live_particle_budget_limit {
            return ParticleRuntimePressureLevel::Critical;
        }
        if live_particle_budget_limit > 0
            && gpu_alive_particle_count as f32 / live_particle_budget_limit as f32 >= 0.9
        {
            return ParticleRuntimePressureLevel::Warning;
        }
        if gpu_alive_particle_count > 0 {
            return ParticleRuntimePressureLevel::Nominal;
        }
        ParticleRuntimePressureLevel::Idle
    }
}

impl Default for ParticleFrameStatsResource {
    fn default() -> Self {
        ParticleFrameStatsResource::new(0.0, Vec::new(), BTreeMap::new(), 0, 0, 0, 0, 0, 0)
    }
}
