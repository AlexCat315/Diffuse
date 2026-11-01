//! `SceneRuntime` — the world, the command buffer and the schedule as one object.
//!
//! Almost every accessor is a forward to `world` or `schedule`; the only state this
//! type owns is which three things it holds. Keeping it that thin is deliberate: a
//! second copy of any of that state would drift from the authoritative one.
//!
//! `tick` is the single place a frame advances. It writes `InputFrameResource` first so
//! scripts can read this frame's input, then runs the schedule.

use crate::entity_id::{EntityID, RuntimeComponent};
use crate::particles::particle_scalability::ParticleScalabilityStateResource;
use crate::particles::particle_simulation_event_apply_report::ParticleSimulationEventApplyReport;
use crate::particles::particle_stats::ParticleFrameStatsResource;
use crate::physics::backend::physics_backend::PhysicsBackend;
use crate::physics::backend::physics_query_scene::PhysicsQueryCacheStats;
use crate::physics::character_controller::CharacterStateFrameResource;
use crate::physics::character_controller::{CharacterCommand, CharacterCommandFrameResource};
use crate::physics::destruction::{
    DestructionCommand, DestructionEventFrameResource, DestructionStateFrameResource,
};
use crate::physics::physics_debug_frame::PhysicsDebugFrameResource;
use crate::physics::physics_events::{PhysicsContactFrameResource, PhysicsEventFrameResource};
use crate::physics::physics_frame_state::{
    PhysicsFrameStateResource, PhysicsStateHashFrameResource, PhysicsStepClockResource,
};
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::queries::physics_query_types::{
    PhysicsHit, PhysicsOverlapAABBQuery, PhysicsOverlapHit, PhysicsOverlapShapeQuery,
    PhysicsQueryFilter, PhysicsQueryOptions, PhysicsQueryResultMode, PhysicsRaycastHit,
    PhysicsRaycastQuery, PhysicsSweepAABBQuery, PhysicsSweepHit, PhysicsSweepShapeQuery,
};
use crate::physics::queries::spatial_queries::{
    SceneOverlapHit, SceneOverlapQuery, SceneRaycastHit, SceneRaycastQuery, SceneSweepHit,
    SceneSweepQuery, SpatialIndexResource, SpatialQueryScratch, SpatialQueryStats,
};
use crate::physics::ragdoll::RagdollStateFrameResource;
use crate::physics::replay::physics_command_tape::{
    PhysicsCommandFrame, PhysicsCommandRecordingResource, PhysicsCommandTape,
};
use crate::physics::replay::physics_replay_report::{
    PhysicsCommandReplayControlResource, PhysicsReplayMismatch, PhysicsReplayReport,
};
use crate::physics::soft_bodies::soft_body::SoftBodyStateFrameResource;
use crate::physics::vehicles::vehicle_state::{
    VehicleCommand, VehicleCommandFrameResource, VehicleStateFrameResource,
};
use crate::rendering::render_extraction::ExtractedRenderSceneResource;
use crate::rendering::render_scene::RenderScene;
use crate::runtime_world::{LocalTransform, RuntimeWorld, RuntimeWorldSummary};
use crate::scheduling::schedule_commands::RuntimeCommandBuffer;
use crate::scheduling::schedule_report::RuntimeScheduleReport;
use crate::scheduling::world_schedule::RuntimeWorldSchedule;
use crate::scripting::RuntimeScriptPhaseContext;

/// A cheap summary of the runtime's state.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SceneRuntimeSnapshot {
    pub entity_count: usize,
    pub revision: u64,
}

impl SceneRuntimeSnapshot {
    pub fn new(entity_count: usize, revision: u64) -> Self {
        SceneRuntimeSnapshot {
            entity_count,
            revision,
        }
    }
}

/// This frame's input, written by `tick` before the schedule runs.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct InputFrameResource {
    pub frame_index: u64,
    pub delta_time_seconds: f64,
    pub events: Vec<diffuse_kernel::input_event::InputEvent>,
}

impl InputFrameResource {
    pub fn new(
        frame_index: u64,
        delta_time_seconds: f64,
        events: Vec<diffuse_kernel::input_event::InputEvent>,
    ) -> Self {
        InputFrameResource {
            frame_index,
            delta_time_seconds,
            events,
        }
    }
}

/// The world, its pending commands, and the frame schedule.
#[derive(Clone)]
pub struct SceneRuntime {
    world: RuntimeWorld,
    command_buffer: RuntimeCommandBuffer,
    schedule: RuntimeWorldSchedule,
}

impl SceneRuntime {
    pub fn new(component_registry: crate::components::core::registry::ComponentRegistry) -> Self {
        SceneRuntime {
            world: RuntimeWorld::new(component_registry),
            command_buffer: RuntimeCommandBuffer::new(),
            schedule: RuntimeWorldSchedule::new(),
        }
    }

    /// Read-only access to the world.
    #[inline]
    pub fn read_world<Result>(&self, body: impl FnOnce(&RuntimeWorld) -> Result) -> Result {
        body(&self.world)
    }

    /// Apply registry-backed authoring or serialization work directly to the world.
    #[inline]
    pub fn with_world<Result>(&mut self, body: impl FnOnce(&mut RuntimeWorld) -> Result) -> Result {
        body(&mut self.world)
    }

    #[inline]
    pub fn world(&self) -> &RuntimeWorld {
        &self.world
    }

    #[inline]
    pub fn world_mut(&mut self) -> &mut RuntimeWorld {
        &mut self.world
    }

    #[inline]
    pub fn component_registry(&self) -> &crate::components::core::registry::ComponentRegistry {
        &self.world.component_registry
    }

    /// Replaces the registry, as Swift's `componentRegistry` setter did.
    #[inline]
    pub fn set_component_registry(
        &mut self,
        registry: crate::components::core::registry::ComponentRegistry,
    ) {
        self.world.component_registry = registry;
    }

    pub fn snapshot(&self) -> SceneRuntimeSnapshot {
        SceneRuntimeSnapshot::new(self.world.entity_count(), self.world.revision())
    }

    pub fn summary(&self) -> RuntimeWorldSummary {
        self.world.summary()
    }

    pub fn extracted_render_scene(&self) -> Option<ExtractedRenderSceneResource> {
        self.world.resource::<ExtractedRenderSceneResource>()
    }

    /// The extracted scene, or an empty one when nothing has been extracted yet.
    pub fn render_scene(&self) -> RenderScene {
        self.extracted_render_scene()
            .map(|extracted| extracted.scene)
            .unwrap_or_else(RenderScene::empty)
    }

    /// The spatial index, building it on demand when no frame has produced one.
    pub fn spatial_index(&self) -> SpatialIndexResource {
        self.world
            .resource::<SpatialIndexResource>()
            .unwrap_or_else(|| {
                crate::physics::queries::spatial_queries::build_spatial_index_resource(
                    &self.world,
                    &diffuse_kernel::job_system::JobSystem::with_available_parallelism(),
                )
                .0
            })
    }

    /// Swift's `particleFrameStats`: an empty stats resource when none was written.
    pub fn particle_frame_stats(&self) -> ParticleFrameStatsResource {
        self.world
            .resource::<ParticleFrameStatsResource>()
            .unwrap_or_else(ParticleFrameStatsResource::empty)
    }

    /// Swift's `particleScalabilityState`: the nominal scale when none was written.
    pub fn particle_scalability_state(&self) -> ParticleScalabilityStateResource {
        self.world
            .resource::<ParticleScalabilityStateResource>()
            .unwrap_or_default()
    }

    pub fn physics_debug_frame(&self) -> PhysicsDebugFrameResource {
        self.world
            .resource::<PhysicsDebugFrameResource>()
            .unwrap_or_else(|| self.schedule.current_physics_debug_frame())
    }

    pub fn physics_event_frame(&self) -> PhysicsEventFrameResource {
        self.world
            .resource::<PhysicsEventFrameResource>()
            .unwrap_or_else(|| self.schedule.current_physics_event_frame())
    }

    pub fn physics_contact_frame(&self) -> PhysicsContactFrameResource {
        self.world
            .resource::<PhysicsContactFrameResource>()
            .unwrap_or_else(|| self.schedule.current_physics_contact_frame())
    }

    pub fn physics_frame_state(&self) -> PhysicsFrameStateResource {
        self.world
            .resource::<PhysicsFrameStateResource>()
            .unwrap_or_else(|| self.schedule.current_physics_frame_state())
    }

    pub fn physics_clock(&self) -> PhysicsStepClockResource {
        self.world
            .resource::<PhysicsStepClockResource>()
            .unwrap_or_else(|| self.schedule.current_physics_clock())
    }

    pub fn destruction_event_frame(&self) -> DestructionEventFrameResource {
        self.world
            .resource::<DestructionEventFrameResource>()
            .unwrap_or_default()
    }

    pub fn destruction_state_frame(&self) -> DestructionStateFrameResource {
        self.world
            .resource::<DestructionStateFrameResource>()
            .unwrap_or_default()
    }

    pub fn character_state_frame(&self) -> CharacterStateFrameResource {
        self.world
            .resource::<CharacterStateFrameResource>()
            .unwrap_or_default()
    }

    pub fn vehicle_state_frame(&self) -> VehicleStateFrameResource {
        self.world
            .resource::<VehicleStateFrameResource>()
            .unwrap_or_default()
    }

    pub fn soft_body_state_frame(&self) -> SoftBodyStateFrameResource {
        self.world
            .resource::<SoftBodyStateFrameResource>()
            .unwrap_or_default()
    }

    pub fn ragdoll_state_frame(&self) -> RagdollStateFrameResource {
        self.world
            .resource::<RagdollStateFrameResource>()
            .unwrap_or_default()
    }

    pub fn physics_state_hash_frame(&self) -> PhysicsStateHashFrameResource {
        self.world
            .resource::<PhysicsStateHashFrameResource>()
            .unwrap_or_default()
    }

    // MARK: - Physics command recording

    pub fn begin_physics_command_recording(&mut self, max_frames: i64) {
        self.world
            .set_resource(PhysicsCommandRecordingResource::new(
                true,
                max_frames,
                Vec::new(),
            ));
    }

    /// Stop recording and return what was captured.
    pub fn end_physics_command_recording(&mut self) -> PhysicsCommandTape {
        let mut recording = self
            .world
            .resource::<PhysicsCommandRecordingResource>()
            .unwrap_or_default();
        recording.is_recording = false;
        self.world.set_resource(recording.clone());
        PhysicsCommandTape::new(recording.frames)
    }

    pub fn physics_command_recording(&self) -> PhysicsCommandRecordingResource {
        self.world
            .resource::<PhysicsCommandRecordingResource>()
            .unwrap_or_default()
    }

    /// Replay one recorded frame: apply its commands, tick, then clear the replay flag.
    pub fn replay_physics_command_frame(
        &mut self,
        frame: PhysicsCommandFrame,
    ) -> RuntimeScheduleReport {
        self.set_physics_settings(frame.settings);
        self.world
            .set_resource(PhysicsCommandReplayControlResource::new(true));

        let mut body_commands = frame.body_commands.clone();
        body_commands.sort_by_key(|command| command.entity.raw_value());
        for command in body_commands {
            let nonzero_force = command.force != diffuse_math::simd::simd_compat::Float3::ZERO;
            let nonzero_torque = command.torque != diffuse_math::simd::simd_compat::Float3::ZERO;
            let nonzero_linear =
                command.linear_impulse != diffuse_math::simd::simd_compat::Float3::ZERO;
            let nonzero_angular =
                command.angular_impulse != diffuse_math::simd::simd_compat::Float3::ZERO;
            if nonzero_force {
                self.apply_force(command.force, command.entity, command.wake);
            }
            if nonzero_torque {
                self.apply_torque(command.torque, command.entity, command.wake);
            }
            if nonzero_linear {
                self.apply_linear_impulse(command.linear_impulse, command.entity, command.wake);
            }
            if nonzero_angular {
                self.apply_angular_impulse(command.angular_impulse, command.entity, command.wake);
            }
        }

        let mut character_commands = frame.character_commands.clone();
        character_commands.sort_by_key(|command| command.entity.raw_value());
        for command in character_commands {
            self.submit_character_command(command.command, command.entity);
        }

        let mut vehicle_commands = frame.vehicle_commands.clone();
        vehicle_commands.sort_by_key(|command| command.entity.raw_value());
        for command in vehicle_commands {
            self.submit_vehicle_command(command.command, command.entity);
        }

        for command in &frame.destruction_commands {
            self.submit_destruction_command(command.clone());
        }

        let report = self.tick(frame.delta_time_seconds, 0, Vec::new());
        self.world
            .set_resource(PhysicsCommandReplayControlResource::default());
        report
    }

    /// Replay a whole tape, comparing each frame's state hash against the record.
    pub fn replay_physics_commands(&mut self, tape: &PhysicsCommandTape) -> PhysicsReplayReport {
        let mut hashes: Vec<u64> = Vec::with_capacity(tape.frames.len());
        let mut mismatches: Vec<PhysicsReplayMismatch> = Vec::new();

        for (index, frame) in tape.frames.iter().enumerate() {
            let _ = self.replay_physics_command_frame(frame.clone());
            let checkpoint = self.physics_state_hash_frame();
            hashes.push(checkpoint.hash);
            if checkpoint.simulated_step != frame.expected_simulated_step
                || checkpoint.hash != frame.expected_state_hash
            {
                mismatches.push(PhysicsReplayMismatch {
                    frame_index: index,
                    expected_simulated_step: frame.expected_simulated_step,
                    actual_simulated_step: checkpoint.simulated_step,
                    expected_state_hash: frame.expected_state_hash,
                    actual_state_hash: checkpoint.hash,
                });
            }
        }

        PhysicsReplayReport::new(tape.frames.len(), hashes, mismatches)
    }

    // MARK: - Ragdoll

    pub fn set_ragdoll_mode(
        &mut self,
        mode: crate::physics::ragdoll::RagdollMode,
        entity: EntityID,
        blend_weight: Option<f32>,
    ) -> bool {
        self.world
            .update_component::<crate::physics::ragdoll::Ragdoll>(entity, |ragdoll| {
                ragdoll.mode = mode;
                if let Some(weight) = blend_weight {
                    // Swift clamped into 0...1; NaN stays NaN through clamp, matching it.
                    ragdoll.blend_weight = weight.clamp(0.0, 1.0);
                }
            })
    }

    pub fn set_ragdoll_bone_simulation(
        &mut self,
        enabled: bool,
        palette_index: i64,
        entity: EntityID,
    ) -> bool {
        let Some(ragdoll) = self
            .world
            .component::<crate::physics::ragdoll::Ragdoll>(entity)
        else {
            return false;
        };
        if !ragdoll
            .bones
            .iter()
            .any(|bone| bone.palette_index == palette_index)
        {
            return false;
        }
        self.world
            .update_component::<crate::physics::ragdoll::Ragdoll>(entity, |ragdoll| {
                if let Some(bone) = ragdoll
                    .bones
                    .iter_mut()
                    .find(|bone| bone.palette_index == palette_index)
                {
                    bone.is_simulation_enabled = enabled;
                }
            })
    }

    /// Merge a GPU-readback report into the frame stats resource.
    pub fn apply_particle_simulation_readback_stats(
        &mut self,
        report: &ParticleSimulationEventApplyReport,
    ) {
        self.world
            .set_resource(self.particle_frame_stats().merging_gpu_readback(report));
    }

    // MARK: - Frame

    /// Advance one frame.
    pub fn tick(
        &mut self,
        delta_time_seconds: f64,
        frame_index: u64,
        input_events: Vec<diffuse_kernel::input_event::InputEvent>,
    ) -> RuntimeScheduleReport {
        self.world.set_resource(InputFrameResource::new(
            frame_index,
            delta_time_seconds,
            input_events,
        ));
        self.schedule.run(
            &mut self.world,
            &mut self.command_buffer,
            delta_time_seconds,
        )
    }

    // MARK: - Entity and component forwarding

    #[inline]
    pub fn contains(&self, entity: EntityID) -> bool {
        self.world.contains(entity)
    }

    pub fn entities(&self) -> Vec<EntityID> {
        self.world.entities()
    }

    pub fn create_entity(&mut self) -> EntityID {
        self.world.create_entity()
    }

    pub fn destroy_entity(&mut self, entity: EntityID) -> bool {
        self.world.destroy_entity(entity)
    }

    pub fn set_component<C: RuntimeComponent>(&mut self, component: C, entity: EntityID) -> bool {
        self.world.set_component(component, entity)
    }

    pub fn component<C: RuntimeComponent>(&self, entity: EntityID) -> Option<C> {
        self.world.component::<C>(entity)
    }

    pub fn has_component<C: RuntimeComponent>(&self, entity: EntityID) -> bool {
        self.world.has_component::<C>(entity)
    }

    pub fn component_count<C: RuntimeComponent>(&self) -> usize {
        self.world.component_count::<C>()
    }

    pub fn entities_with<C: RuntimeComponent>(&self) -> Vec<EntityID> {
        self.world.entities_with::<C>()
    }

    pub fn query<C: RuntimeComponent>(
        &self,
    ) -> Vec<crate::runtime_world::RuntimeComponentQuery<C>> {
        self.world.query::<C>()
    }

    /// Swift's `query(_:using:)`: the same query, run through the job system.
    pub fn query_with_job_system<C: RuntimeComponent>(
        &self,
        job_system: &diffuse_kernel::job_system::JobSystem,
    ) -> (
        Vec<crate::runtime_world::RuntimeComponentQuery<C>>,
        diffuse_kernel::job_system::JobDispatchReport,
    ) {
        let entities = self.world.entities_with::<C>();
        let snapshot = self.world.component_snapshot_matching::<C>(&entities);
        job_system.parallel_compact_map(&entities, None, |entity| {
            snapshot.get(entity).cloned().map(|component| {
                crate::runtime_world::RuntimeComponentQuery::new(*entity, component)
            })
        })
    }

    pub fn query_pair<A: RuntimeComponent, B: RuntimeComponent>(
        &self,
    ) -> Vec<crate::runtime_world::RuntimeComponentPairQuery<A, B>> {
        self.world.query_pair::<A, B>()
    }

    /// Swift's `query(_:_:using:)`: the pair query, run through the job system.
    pub fn query_pair_with_job_system<A: RuntimeComponent, B: RuntimeComponent>(
        &self,
        job_system: &diffuse_kernel::job_system::JobSystem,
    ) -> (
        Vec<crate::runtime_world::RuntimeComponentPairQuery<A, B>>,
        diffuse_kernel::job_system::JobDispatchReport,
    ) {
        let entities = self.world.entities_with::<A>();
        let snapshot_a = self.world.component_snapshot_matching::<A>(&entities);
        let snapshot_b = self.world.component_snapshot_matching::<B>(&entities);
        job_system.parallel_compact_map(&entities, None, |entity| {
            Some(crate::runtime_world::RuntimeComponentPairQuery::new(
                *entity,
                snapshot_a.get(entity)?.clone(),
                snapshot_b.get(entity)?.clone(),
            ))
        })
    }

    pub fn query_triple<A: RuntimeComponent, B: RuntimeComponent, C: RuntimeComponent>(
        &self,
    ) -> Vec<crate::runtime_world::RuntimeComponentTripleQuery<A, B, C>> {
        self.world.query_triple::<A, B, C>()
    }

    /// Swift's `query(_:_:_:using:)`: the triple query, run through the job system.
    pub fn query_triple_with_job_system<
        A: RuntimeComponent,
        B: RuntimeComponent,
        C: RuntimeComponent,
    >(
        &self,
        job_system: &diffuse_kernel::job_system::JobSystem,
    ) -> (
        Vec<crate::runtime_world::RuntimeComponentTripleQuery<A, B, C>>,
        diffuse_kernel::job_system::JobDispatchReport,
    ) {
        let entities = self.world.entities_with::<A>();
        let snapshot_a = self.world.component_snapshot_matching::<A>(&entities);
        let snapshot_b = self.world.component_snapshot_matching::<B>(&entities);
        let snapshot_c = self.world.component_snapshot_matching::<C>(&entities);
        job_system.parallel_compact_map(&entities, None, |entity| {
            Some(crate::runtime_world::RuntimeComponentTripleQuery::new(
                *entity,
                snapshot_a.get(entity)?.clone(),
                snapshot_b.get(entity)?.clone(),
                snapshot_c.get(entity)?.clone(),
            ))
        })
    }

    pub fn update_component<C: RuntimeComponent>(
        &mut self,
        entity: EntityID,
        body: impl FnOnce(&mut C),
    ) -> bool {
        self.world.update_component::<C>(entity, body)
    }

    pub fn update_components<C: RuntimeComponent>(
        &mut self,
        body: impl FnMut(EntityID, &mut C),
    ) -> usize {
        self.world.update_components::<C>(body)
    }

    pub fn remove_component<C: RuntimeComponent>(&mut self, entity: EntityID) -> Option<C> {
        self.world.remove_component::<C>(entity)
    }

    pub fn set_local_transform(&mut self, transform: LocalTransform, entity: EntityID) -> bool {
        self.world.set_local_transform(transform, entity)
    }

    #[inline]
    pub fn local_transform(&self, entity: EntityID) -> Option<LocalTransform> {
        self.world.local_transform(entity)
    }

    pub fn world_transform(
        &self,
        entity: EntityID,
    ) -> Option<crate::runtime_world::WorldTransform> {
        self.world.world_transform(entity)
    }

    #[inline]
    pub fn parent(&self, entity: EntityID) -> Option<EntityID> {
        self.world.parent(entity)
    }

    #[inline]
    pub fn children(&self, entity: EntityID) -> Vec<EntityID> {
        self.world.children(entity)
    }

    pub fn roots(&self) -> Vec<EntityID> {
        self.world.roots()
    }

    /// The first entity whose `SceneNameComponent.value` equals `name`.
    pub fn find_entity_named(&self, name: &str) -> Option<EntityID> {
        self.world
            .entities_with::<crate::scene_bootstrap::SceneNameComponent>()
            .into_iter()
            .find(|&id| {
                self.world
                    .component::<crate::scene_bootstrap::SceneNameComponent>(id)
                    .is_some_and(|component| component.value == name)
            })
    }

    /// Every entity whose `SceneKindComponent.value` equals `kind`.
    pub fn entities_kind(&self, kind: &str) -> Vec<EntityID> {
        self.world
            .entities_with::<crate::scene_bootstrap::SceneKindComponent>()
            .into_iter()
            .filter(|id| {
                self.world
                    .component::<crate::scene_bootstrap::SceneKindComponent>(*id)
                    .is_some_and(|component| component.value == kind)
            })
            .collect()
    }

    pub fn set_parent(&mut self, parent: Option<EntityID>, child: EntityID) -> bool {
        self.world.set_parent(parent, child)
    }

    pub fn move_entity(&mut self, entity: EntityID, parent: Option<EntityID>, index: i64) -> bool {
        self.world.move_entity(entity, parent, index)
    }

    pub fn hierarchy_needs_propagation(&self) -> bool {
        self.world.hierarchy_needs_propagation()
    }

    pub fn propagate_transforms(&mut self) {
        self.world.propagate_transforms_default();
    }

    pub fn resource<R: Send + Sync + Clone + 'static>(&self) -> Option<R> {
        self.world.resource::<R>()
    }

    pub fn set_resource<R: Send + Sync + Clone + 'static>(&mut self, resource: R) {
        self.world.set_resource(resource);
    }

    pub fn update_resource<R: Send + Sync + Clone + 'static>(
        &mut self,
        body: impl FnOnce(&mut R),
    ) -> bool {
        self.world.update_resource::<R>(body)
    }

    pub fn remove_resource<R: Send + Sync + Clone + 'static>(&mut self) -> Option<R> {
        self.world.remove_resource::<R>()
    }

    pub fn physics_settings(&self) -> PhysicsSettingsResource {
        self.world
            .resource::<PhysicsSettingsResource>()
            .unwrap_or_default()
    }

    pub fn set_physics_settings(&mut self, settings: PhysicsSettingsResource) {
        self.world.set_resource(settings);
        self.schedule.ensure_backend_matches(&self.world);
    }

    pub fn physics_query_cache_stats(&self) -> PhysicsQueryCacheStats {
        self.schedule.current_physics_query_cache_stats()
    }

    // MARK: - Commands

    pub fn enqueue(&mut self, command: crate::scheduling::schedule_commands::RuntimeCommand) {
        self.command_buffer.enqueue(command);
    }

    pub fn create_queued_entity(&mut self) {
        self.command_buffer.create_entity();
    }

    pub fn destroy_queued_entity(&mut self, entity: EntityID) {
        self.command_buffer.destroy_entity(entity);
    }

    pub fn set_queued_parent(&mut self, parent: Option<EntityID>, child: EntityID) {
        self.command_buffer.set_parent(parent, child);
    }

    pub fn set_queued_local_transform(&mut self, transform: LocalTransform, entity: EntityID) {
        self.command_buffer.set_local_transform(transform, entity);
    }

    pub fn enqueue_destroy_entity(&mut self, entity: EntityID) {
        self.destroy_queued_entity(entity);
    }

    pub fn enqueue_set_parent(&mut self, parent: Option<EntityID>, child: EntityID) {
        self.set_queued_parent(parent, child);
    }

    pub fn enqueue_set_local_transform(&mut self, transform: LocalTransform, entity: EntityID) {
        self.set_queued_local_transform(transform, entity);
    }

    pub fn submit_character_command(&mut self, command: CharacterCommand, entity: EntityID) {
        let mut frame = self
            .world
            .resource::<CharacterCommandFrameResource>()
            .unwrap_or_default();
        frame.commands.insert(entity, command);
        self.world.set_resource(frame);
    }

    pub fn submit_vehicle_command(&mut self, command: VehicleCommand, entity: EntityID) {
        let mut frame = self
            .world
            .resource::<VehicleCommandFrameResource>()
            .unwrap_or_default();
        frame.commands.insert(entity, command);
        self.world.set_resource(frame);
    }

    pub fn submit_destruction_command(&mut self, command: DestructionCommand) {
        let mut frame = self
            .world
            .resource::<crate::physics::destruction::DestructionCommandFrameResource>()
            .unwrap_or_default();
        frame.commands.push(command);
        self.world.set_resource(frame);
    }

    // MARK: - Forces

    pub fn apply_force(
        &mut self,
        force: diffuse_math::simd::simd_compat::Float3,
        entity: EntityID,
        wake: bool,
    ) -> bool {
        self.world.apply_force(force, entity, wake)
    }

    /// Swift's `applyForce(_:at:to:wake:)` overload: the force is applied at a
    /// world point, so it also contributes torque about the body's centre.
    pub fn apply_force_at(
        &mut self,
        force: diffuse_math::simd::simd_compat::Float3,
        world_point: diffuse_math::simd::simd_compat::Float3,
        entity: EntityID,
        wake: bool,
    ) -> bool {
        self.world.apply_force_at(force, world_point, entity, wake)
    }

    pub fn apply_torque(
        &mut self,
        torque: diffuse_math::simd::simd_compat::Float3,
        entity: EntityID,
        wake: bool,
    ) -> bool {
        self.world.apply_torque(torque, entity, wake)
    }

    pub fn apply_linear_impulse(
        &mut self,
        impulse: diffuse_math::simd::simd_compat::Float3,
        entity: EntityID,
        wake: bool,
    ) -> bool {
        self.world.apply_linear_impulse(impulse, entity, wake)
    }

    /// Swift's `applyLinearImpulse(_:at:to:wake:)` overload.
    pub fn apply_linear_impulse_at(
        &mut self,
        impulse: diffuse_math::simd::simd_compat::Float3,
        world_point: diffuse_math::simd::simd_compat::Float3,
        entity: EntityID,
        wake: bool,
    ) -> bool {
        self.world
            .apply_linear_impulse_at(impulse, world_point, entity, wake)
    }

    pub fn apply_angular_impulse(
        &mut self,
        impulse: diffuse_math::simd::simd_compat::Float3,
        entity: EntityID,
        wake: bool,
    ) -> bool {
        self.world.apply_angular_impulse(impulse, entity, wake)
    }

    pub fn wake_rigid_body(&mut self, entity: EntityID) -> bool {
        self.world.wake_rigid_body(entity)
    }

    pub fn sleep_rigid_body(&mut self, entity: EntityID) -> bool {
        self.world.sleep_rigid_body(entity)
    }

    pub fn clear_forces(&mut self, entity: EntityID) -> bool {
        self.world.clear_forces(entity)
    }

    // MARK: - Queries

    /// Replaces Swift's `raycast(_ query: SceneRaycastQuery)`: the scene-level
    /// convenience query, converted from the backend's physics hit.
    ///
    /// Takes `&mut self` because the schedule's query cache counts the query and
    /// may rebuild the mirrored backend (Swift's `PhysicsQueryScene` is a class).
    pub fn raycast_scene(&mut self, query: SceneRaycastQuery) -> Option<SceneRaycastHit> {
        let filter = PhysicsQueryFilter {
            include_triggers: query.include_triggers,
            ..PhysicsQueryFilter::default()
        };
        self.schedule
            .physics_query_backend(&self.world)
            .raycast(
                PhysicsRaycastQuery::with_distance(
                    query.origin,
                    query.direction,
                    query.max_distance,
                ),
                filter,
            )
            .map(|hit| make_scene_raycast_hit(&hit))
    }

    /// Swift's `physicsRaycast(_:filter:)`.
    pub fn physics_raycast(
        &mut self,
        query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsRaycastHit> {
        self.schedule
            .physics_query_backend(&self.world)
            .raycast(query, filter)
    }

    /// Replaces Swift's `raycast(_ query: PhysicsRaycastQuery, options:)`.
    ///
    /// All-hit results are stable-sorted by distance, entity ID, then sub-shape ID
    /// (the backend's `raycastAll` contract), and truncated to `max_hits`.
    pub fn raycast_all_options(
        &mut self,
        query: PhysicsRaycastQuery,
        options: PhysicsQueryOptions,
    ) -> Vec<PhysicsHit> {
        let PhysicsQueryOptions {
            filter,
            result_mode,
            max_hits,
        } = options;
        let backend = self.schedule.physics_query_backend(&self.world);
        let hits: Vec<PhysicsRaycastHit> = match result_mode {
            PhysicsQueryResultMode::Nearest => backend.raycast(query, filter).into_iter().collect(),
            PhysicsQueryResultMode::All => backend.raycast_all(query, filter, max_hits),
        };
        hits.into_iter()
            .take(max_hits)
            .map(|hit| {
                PhysicsHit::new(
                    hit.entity,
                    hit.sub_shape_id,
                    hit.distance,
                    if query.max_distance > 0.0 {
                        hit.distance / query.max_distance
                    } else {
                        0.0
                    },
                    hit.position,
                    hit.normal,
                    hit.bounds,
                    hit.is_trigger,
                )
            })
            .collect()
    }

    /// Swift's `raycastBatch(_:options:)`: each query runs against the same
    /// synchronized physics snapshot.
    pub fn raycast_batch(
        &mut self,
        queries: Vec<PhysicsRaycastQuery>,
        options: PhysicsQueryOptions,
    ) -> Vec<Vec<PhysicsHit>> {
        queries
            .into_iter()
            .map(|query| self.raycast_all_options(query, options.clone()))
            .collect()
    }

    /// Swift's `physicsRaycastWithStats(_:filter:scratch:)`. The scratch handle
    /// carries no state in the Rust port, so the returned stats are zeroed.
    pub fn physics_raycast_with_stats(
        &mut self,
        query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter,
        _scratch: Option<&SpatialQueryScratch>,
    ) -> (Option<PhysicsRaycastHit>, SpatialQueryStats) {
        let hit = self
            .schedule
            .physics_query_backend(&self.world)
            .raycast(query, filter);
        (hit, SpatialQueryStats::default())
    }

    /// Replaces Swift's `overlap(_ query: SceneOverlapQuery)`.
    pub fn overlap_scene(&mut self, query: SceneOverlapQuery) -> Vec<SceneOverlapHit> {
        let filter = PhysicsQueryFilter {
            include_triggers: query.include_triggers,
            ..PhysicsQueryFilter::default()
        };
        self.schedule
            .physics_query_backend(&self.world)
            .overlap_aabb(PhysicsOverlapAABBQuery::new(query.bounds), filter)
            .into_iter()
            .map(|hit| make_scene_overlap_hit(&hit))
            .collect()
    }

    /// Replaces Swift's `overlap(_ query: SceneOverlapQuery, scratch:)` overload.
    pub fn overlap_scene_with_scratch(
        &mut self,
        query: SceneOverlapQuery,
        _scratch: &SpatialQueryScratch,
    ) -> Vec<SceneOverlapHit> {
        self.overlap_scene(query)
    }

    /// Swift's `overlapWithStats(_:scratch:)`.
    pub fn overlap_scene_with_stats(
        &mut self,
        query: SceneOverlapQuery,
        _scratch: Option<&SpatialQueryScratch>,
    ) -> (Vec<SceneOverlapHit>, SpatialQueryStats) {
        (self.overlap_scene(query), SpatialQueryStats::default())
    }

    /// Swift's `physicsOverlapAABB(_:filter:)`.
    pub fn physics_overlap_aabb(
        &mut self,
        query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        self.schedule
            .physics_query_backend(&self.world)
            .overlap_aabb(query, filter)
    }

    /// Replaces Swift's `physicsOverlapAABB(_:filter:scratch:)` overload.
    pub fn physics_overlap_aabb_with_scratch(
        &mut self,
        query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter,
        _scratch: &SpatialQueryScratch,
    ) -> Vec<PhysicsOverlapHit> {
        self.physics_overlap_aabb(query, filter)
    }

    /// Swift's `physicsOverlapAABBWithStats(_:filter:scratch:)`.
    pub fn physics_overlap_aabb_with_stats(
        &mut self,
        query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter,
        _scratch: Option<&SpatialQueryScratch>,
    ) -> (Vec<PhysicsOverlapHit>, SpatialQueryStats) {
        (
            self.physics_overlap_aabb(query, filter),
            SpatialQueryStats::default(),
        )
    }

    /// Swift's `physicsOverlapShape(_:filter:)`.
    pub fn physics_overlap_shape(
        &mut self,
        query: PhysicsOverlapShapeQuery,
        filter: PhysicsQueryFilter,
    ) -> Vec<PhysicsOverlapHit> {
        self.schedule
            .physics_query_backend(&self.world)
            .overlap_shape(query, filter)
    }

    /// Swift's `overlapShape(_:options:)`. `Nearest` limits the query itself to one
    /// result; `All` uses `max_hits`. Results are sorted by entity then sub-shape.
    pub fn overlap_shape(
        &mut self,
        query: PhysicsOverlapShapeQuery,
        options: PhysicsQueryOptions,
    ) -> Vec<PhysicsHit> {
        let limit = match options.result_mode {
            PhysicsQueryResultMode::Nearest => 1,
            PhysicsQueryResultMode::All => options.max_hits,
        };
        let mut limited_query = query;
        limited_query.max_results = limit;
        let mut hits = self
            .schedule
            .physics_query_backend(&self.world)
            .overlap_shape(limited_query, options.filter);
        hits.sort_by(|left, right| {
            if left.entity.raw_value() != right.entity.raw_value() {
                return left.entity.raw_value().cmp(&right.entity.raw_value());
            }
            left.sub_shape_id.cmp(&right.sub_shape_id)
        });
        hits.into_iter()
            .take(limit)
            .map(|hit| PhysicsHit {
                entity: hit.entity,
                sub_shape_id: hit.sub_shape_id,
                distance: 0.0,
                fraction: 0.0,
                position: diffuse_math::simd::simd_compat::Float3::ZERO,
                normal: diffuse_math::simd::simd_compat::Float3::ZERO,
                bounds: hit.bounds,
                is_trigger: hit.is_trigger,
            })
            .collect()
    }

    /// Swift's `overlapShapeBatch(_:options:)`.
    pub fn overlap_shape_batch(
        &mut self,
        queries: Vec<PhysicsOverlapShapeQuery>,
        options: PhysicsQueryOptions,
    ) -> Vec<Vec<PhysicsHit>> {
        queries
            .into_iter()
            .map(|query| self.overlap_shape(query, options.clone()))
            .collect()
    }

    /// Swift's `physicsOverlapShapeWithStats(_:filter:scratch:)`.
    pub fn physics_overlap_shape_with_stats(
        &mut self,
        query: PhysicsOverlapShapeQuery,
        filter: PhysicsQueryFilter,
        _scratch: Option<&SpatialQueryScratch>,
    ) -> (Vec<PhysicsOverlapHit>, SpatialQueryStats) {
        (
            self.physics_overlap_shape(query, filter),
            SpatialQueryStats::default(),
        )
    }

    /// Replaces Swift's `sweep(_ query: SceneSweepQuery)`.
    pub fn sweep(&mut self, query: SceneSweepQuery) -> Option<SceneSweepHit> {
        let filter = PhysicsQueryFilter {
            include_triggers: query.include_triggers,
            ..PhysicsQueryFilter::default()
        };
        self.schedule
            .physics_query_backend(&self.world)
            .sweep_aabb(
                PhysicsSweepAABBQuery::new(query.bounds, query.translation),
                filter,
            )
            .map(|hit| make_scene_sweep_hit(&hit))
    }

    /// Swift's `physicsSweepAABB(_:filter:)`.
    pub fn physics_sweep_aabb(
        &mut self,
        query: PhysicsSweepAABBQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        self.schedule
            .physics_query_backend(&self.world)
            .sweep_aabb(query, filter)
    }

    /// Swift's `physicsSweepAABBWithStats(_:filter:scratch:)`.
    pub fn physics_sweep_aabb_with_stats(
        &mut self,
        query: PhysicsSweepAABBQuery,
        filter: PhysicsQueryFilter,
        _scratch: Option<&SpatialQueryScratch>,
    ) -> (Option<PhysicsSweepHit>, SpatialQueryStats) {
        (
            self.physics_sweep_aabb(query, filter),
            SpatialQueryStats::default(),
        )
    }

    /// Swift's `physicsSweepShape(_:filter:)`.
    pub fn physics_sweep_shape(
        &mut self,
        query: PhysicsSweepShapeQuery,
        filter: PhysicsQueryFilter,
    ) -> Option<PhysicsSweepHit> {
        self.schedule
            .physics_query_backend(&self.world)
            .sweep_shape(query, filter)
    }

    /// Swift's `shapeCast(_:options:)`.
    pub fn shape_cast(
        &mut self,
        query: PhysicsSweepShapeQuery,
        options: PhysicsQueryOptions,
    ) -> Vec<PhysicsHit> {
        let PhysicsQueryOptions {
            filter,
            result_mode,
            max_hits,
        } = options;
        let backend = self.schedule.physics_query_backend(&self.world);
        let hits: Vec<PhysicsSweepHit> = match result_mode {
            PhysicsQueryResultMode::Nearest => {
                backend.sweep_shape(query, filter).into_iter().collect()
            }
            PhysicsQueryResultMode::All => backend.sweep_shape_all(query, filter, max_hits),
        };
        hits.into_iter()
            .take(max_hits)
            .map(|hit| {
                PhysicsHit::new(
                    hit.entity,
                    hit.sub_shape_id,
                    hit.distance,
                    hit.fraction,
                    hit.position,
                    hit.normal,
                    hit.bounds,
                    hit.is_trigger,
                )
            })
            .collect()
    }

    /// Swift's `shapeCastBatch(_:options:)`.
    pub fn shape_cast_batch(
        &mut self,
        queries: Vec<PhysicsSweepShapeQuery>,
        options: PhysicsQueryOptions,
    ) -> Vec<Vec<PhysicsHit>> {
        queries
            .into_iter()
            .map(|query| self.shape_cast(query, options.clone()))
            .collect()
    }

    /// Swift's `physicsSweepShapeWithStats(_:filter:scratch:)`.
    pub fn physics_sweep_shape_with_stats(
        &mut self,
        query: PhysicsSweepShapeQuery,
        filter: PhysicsQueryFilter,
        _scratch: Option<&SpatialQueryScratch>,
    ) -> (Option<PhysicsSweepHit>, SpatialQueryStats) {
        (
            self.physics_sweep_shape(query, filter),
            SpatialQueryStats::default(),
        )
    }

    // MARK: - Schedule access

    /// Swift's `setPhysicsBackend(_:)`.
    pub fn set_physics_backend(&mut self, backend: Box<dyn PhysicsBackend>) {
        self.schedule.set_physics_backend(backend);
    }

    /// Swift's `clearPhysicsBackendOverride()`.
    pub fn clear_physics_backend_override(&mut self) {
        self.schedule.clear_physics_backend_override();
    }

    #[inline]
    pub fn schedule(&self) -> &RuntimeWorldSchedule {
        &self.schedule
    }

    #[inline]
    pub fn schedule_mut(&mut self) -> &mut RuntimeWorldSchedule {
        &mut self.schedule
    }

    pub fn set_script_driver(
        &mut self,
        driver: impl Into<crate::scripting::SharedRuntimeScriptDriver>,
    ) {
        self.schedule.set_script_driver(driver);
    }

    pub fn clear_script_driver(&mut self) {
        self.schedule.clear_script_driver();
    }

    /// Swift's `setJobSystem(_:)`: replaces the schedule's worker pool.
    pub fn set_job_system(&mut self, job_system: diffuse_kernel::job_system::JobSystem) {
        self.schedule.set_job_system(job_system);
    }

    /// Runs a script driver against this scene's world for one frame.
    ///
    pub fn run_script_driver(
        &mut self,
        driver: &mut dyn crate::scripting::RuntimeScriptDriver,
        delta_time: f64,
    ) {
        let mut context = RuntimeScriptPhaseContext::with_physics_query_scene(
            &mut self.world,
            &mut self.command_buffer,
            delta_time,
            self.schedule.physics_query_scene(),
        );
        driver.run(&mut context);
    }
}

/// Swift's `makeSceneRaycastHit(_:)` converter.
fn make_scene_raycast_hit(hit: &PhysicsRaycastHit) -> SceneRaycastHit {
    SceneRaycastHit::new(
        hit.entity,
        hit.distance,
        hit.position,
        hit.normal,
        hit.bounds,
        hit.is_trigger,
    )
}

/// Swift's `makeSceneOverlapHit(_:)` converter.
fn make_scene_overlap_hit(hit: &PhysicsOverlapHit) -> SceneOverlapHit {
    SceneOverlapHit::new(hit.entity, hit.bounds, hit.is_trigger)
}

/// Swift's `makeSceneSweepHit(_:)` converter.
fn make_scene_sweep_hit(hit: &PhysicsSweepHit) -> SceneSweepHit {
    SceneSweepHit::new(
        hit.entity,
        hit.fraction,
        hit.distance,
        hit.position,
        hit.normal,
        hit.bounds,
        hit.is_trigger,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;
    use crate::scene_bootstrap::SceneNameComponent;

    fn runtime() -> SceneRuntime {
        SceneRuntime::new(ComponentRegistry::new())
    }

    #[test]
    fn a_new_runtime_is_empty() {
        let runtime = runtime();
        assert_eq!(runtime.snapshot().entity_count, 0);
        assert!(runtime.entities().is_empty());
    }

    #[test]
    fn creating_an_entity_updates_the_snapshot() {
        let mut runtime = runtime();
        let entity = runtime.create_entity();
        assert!(runtime.contains(entity));
        assert_eq!(runtime.snapshot().entity_count, 1);
    }

    #[test]
    fn components_round_trip_through_the_runtime() {
        let mut runtime = runtime();
        let entity = runtime.create_entity();
        assert!(runtime.set_component(SceneNameComponent::new("hero"), entity));
        assert_eq!(
            runtime
                .component::<SceneNameComponent>(entity)
                .map(|name| name.value),
            Some("hero".to_string())
        );
    }

    #[test]
    fn a_tick_advances_the_revision_and_returns_a_report() {
        let mut runtime = runtime();
        let before = runtime.snapshot().revision;
        let report = runtime.tick(1.0 / 60.0, 0, Vec::new());
        assert!(runtime.snapshot().revision > before);
        assert_eq!(report.phases.len(), 10);
    }

    #[test]
    fn a_tick_writes_the_input_frame_before_running() {
        let mut runtime = runtime();
        runtime.tick(1.0 / 60.0, 7, Vec::new());
        let input = runtime
            .resource::<InputFrameResource>()
            .expect("input frame");
        assert_eq!(input.frame_index, 7);
        assert!((input.delta_time_seconds - 1.0 / 60.0).abs() < 1e-12);
    }

    #[test]
    fn an_empty_runtime_renders_an_empty_scene() {
        let runtime = runtime();
        assert!(runtime.render_scene().instances.is_empty());
    }

    #[test]
    fn the_spatial_index_is_built_on_demand() {
        let mut runtime = runtime();
        let entity = runtime.create_entity();
        runtime.set_component(
            crate::physics::collider::Collider::with_shape(
                crate::physics::collider::ColliderShape::Box {
                    half_extents: diffuse_math::simd::simd_compat::Float3::splat(1.0),
                    center: diffuse_math::simd::simd_compat::Float3::ZERO,
                },
            ),
            entity,
        );
        assert_eq!(runtime.spatial_index().entries.len(), 1);
    }

    #[test]
    fn recording_round_trips_through_a_tape() {
        let mut runtime = runtime();
        runtime.begin_physics_command_recording(16);
        assert!(runtime.physics_command_recording().is_recording);
        let tape = runtime.end_physics_command_recording();
        assert!(!runtime.physics_command_recording().is_recording);
        assert!(tape.frames.is_empty());
    }

    #[test]
    fn applying_a_force_accumulates_and_wakes() {
        use diffuse_math::simd::simd_compat::Float3;

        let mut runtime = runtime();
        let entity = runtime.create_entity();
        let body = crate::physics::rigid_body::RigidBody {
            is_sleeping: true,
            ..crate::physics::rigid_body::RigidBody::default()
        };
        runtime.set_component(body, entity);

        assert!(runtime.apply_force(Float3::new(1.0, 0.0, 0.0), entity, true));
        let body = runtime
            .component::<crate::physics::rigid_body::RigidBody>(entity)
            .expect("body");
        assert_eq!(body.accumulated_force.x, 1.0);
        assert!(
            !body.is_sleeping,
            "a waking force must clear the sleep flag"
        );
    }
}
