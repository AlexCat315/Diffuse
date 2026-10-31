//! Scene-level particle stepping, immediate emission and simulation-event apply.
//!
//! Ported from `Engine/Sources/SceneRuntime/Particles/Runtime.swift`.

use std::collections::BTreeMap;

use diffuse_math::simd::simd_compat::{Float4x4, MATRIX_IDENTITY_FLOAT4X4};

use crate::entity_id::EntityID;
use crate::particles::emitter::particle_emitter::ParticleEmitter;
use crate::particles::particle_events::ParticleEvent;
use crate::particles::particle_scalability::{
    ParticleScalabilityPolicyResource, ParticleScalabilityStateResource,
};
use crate::particles::particle_simulation_event_apply_report::ParticleSimulationEventApplyReport;
use crate::particles::particle_stats::{ParticleEmitterFrameStats, ParticleFrameStatsResource};
use crate::particles::particle_types::ParticleAdvanceOptions;
use crate::scene_runtime::SceneRuntime;

impl SceneRuntime {
    /// Advances every `ParticleEmitter` in the scene by `delta_time` seconds.
    /// Returns the number of emitters stepped.
    pub fn advance_particles(
        &mut self,
        delta_time: f64,
        options: ParticleAdvanceOptions,
    ) -> usize {
        let particle_entities = self.world().entities_with::<ParticleEmitter>();
        let mut world_transforms: BTreeMap<EntityID, Float4x4> = BTreeMap::new();
        for entity in &particle_entities {
            let matrix = self
                .world()
                .world_transform(*entity)
                .map(|transform| transform.matrix)
                .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
            world_transforms.insert(*entity, matrix);
        }
        let policy = self
            .resource::<ParticleScalabilityPolicyResource>()
            .unwrap_or_else(ParticleScalabilityPolicyResource::disabled);
        let previous_stats = self
            .resource::<ParticleFrameStatsResource>()
            .unwrap_or_default();
        let previous_state = self
            .resource::<ParticleScalabilityStateResource>()
            .unwrap_or_default();
        let scalability_state = policy.updated_state(&previous_stats, previous_state);
        self.set_resource(scalability_state);
        let effective_options = scalability_state.applying(options);
        let mut particle_stats: Vec<ParticleEmitterFrameStats> =
            Vec::with_capacity(particle_entities.len());
        let mut particle_stats_by_entity: BTreeMap<u64, ParticleEmitterFrameStats> =
            BTreeMap::new();
        let stepped = self
            .world_mut()
            .update_components::<ParticleEmitter>(|entity, emitter| {
                let world_transform = world_transforms
                    .get(&entity)
                    .copied()
                    .unwrap_or(MATRIX_IDENTITY_FLOAT4X4);
                emitter.advance(delta_time, Some(world_transform), &effective_options);
                let stats = emitter.last_frame_stats();
                particle_stats.push(stats);
                particle_stats_by_entity.insert(entity.raw_value(), stats);
            });
        self.set_resource(ParticleFrameStatsResource::new(
            delta_time.max(0.0) as f32,
            particle_stats,
            particle_stats_by_entity,
            0,
            0,
            0,
            0,
            0,
            0,
        ));
        stepped
    }

    /// Emits particles immediately from one entity's `ParticleEmitter`.
    /// Returns false when the entity has no particle emitter.
    pub fn emit_particles(&mut self, entity: EntityID, count: i64) -> bool {
        let transform = self.world_transform(entity).map(|world| world.matrix);
        self.update_component::<ParticleEmitter>(entity, |emitter| {
            emitter.emit(count, transform);
        })
    }

    pub fn apply_particle_simulation_events(
        &mut self,
        events_by_entity: &BTreeMap<EntityID, Vec<ParticleEvent>>,
    ) -> ParticleSimulationEventApplyReport {
        let mut report = ParticleSimulationEventApplyReport::new(
            events_by_entity.len() as i64,
            0,
            0,
            0,
            events_by_entity
                .values()
                .map(|events| events.len() as i64)
                .sum(),
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
        );
        let mut emitter_stats: Vec<ParticleEmitterFrameStats> =
            Vec::with_capacity(events_by_entity.len());
        let mut emitter_stats_by_entity: BTreeMap<u64, ParticleEmitterFrameStats> =
            BTreeMap::new();
        for (entity, events) in events_by_entity {
            if events.is_empty() {
                report.empty_event_emitter_count += 1;
                continue;
            }
            let mut applied_stats: Option<ParticleEmitterFrameStats> = None;
            let updated = self.update_component::<ParticleEmitter>(*entity, |emitter| {
                let stats = emitter.apply_simulation_events(events);
                applied_stats = Some(stats);
                emitter_stats.push(stats);
                emitter_stats_by_entity.insert(entity.raw_value(), stats);
            });
            if updated {
                if let Some(applied_stats) = applied_stats {
                    report.applied_emitter_count += 1;
                    report.applied_event_count += events.len() as i64;
                    report.collision_event_count += applied_stats.collision_count;
                    report.death_event_count += applied_stats.expired_particle_count;
                    report.sub_emitter_spawned_count += applied_stats.sub_emitter_spawned_count;
                    report.spawned_particle_count += applied_stats.spawned_particle_count();
                    report.requested_spawn_count += applied_stats.requested_spawn_count;
                    report.spawn_budget_limit += applied_stats.spawn_budget_limit;
                    report.spawn_budget_consumed_count += applied_stats.spawn_budget_consumed_count;
                    report.capacity_limited_spawn_count +=
                        applied_stats.capacity_limited_spawn_count;
                    report.spawn_budget_limited_count += applied_stats.spawn_budget_limited_count;
                }
            } else {
                report.missing_emitter_count += 1;
            }
        }
        if !emitter_stats.is_empty() {
            self.set_resource(ParticleFrameStatsResource::new(
                0.0,
                emitter_stats,
                emitter_stats_by_entity.clone(),
                0,
                0,
                0,
                0,
                0,
                0,
            ));
        }
        report.emitter_stats_by_entity = emitter_stats_by_entity;
        report
    }
}
