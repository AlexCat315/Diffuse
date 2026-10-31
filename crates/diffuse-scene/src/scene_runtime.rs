//! `SceneRuntime` — the world, the command buffer and the schedule as one object.
//!
//! Almost every accessor is a forward to `world` or `schedule`; the only state this
//! type owns is which three things it holds. Keeping it that thin is deliberate: a
//! second copy of any of that state would drift from the authoritative one.
//!
//! `tick` is the single place a frame advances. It writes `InputFrameResource` first so
//! scripts can read this frame's input, then runs the schedule.

use crate::entity_id::{EntityID, RuntimeComponent};
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
use crate::physics::queries::spatial_queries::SpatialIndexResource;
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

    pub fn update_component<C: RuntimeComponent>(
        &mut self,
        entity: EntityID,
        body: impl FnOnce(&mut C),
    ) -> bool {
        self.world.update_component::<C>(entity, body)
    }

    pub fn remove_component<C: RuntimeComponent>(&mut self, entity: EntityID) -> Option<C> {
        self.world.remove_component::<C>(entity)
    }

    #[inline]
    pub fn local_transform(&self, entity: EntityID) -> Option<LocalTransform> {
        self.world.local_transform(entity)
    }

    pub fn set_local_transform(&mut self, transform: LocalTransform, entity: EntityID) -> bool {
        self.world.set_local_transform(transform, entity)
    }

    pub fn world_transform(
        &self,
        entity: EntityID,
    ) -> Option<crate::runtime_world::WorldTransform> {
        self.world.world_transform(entity)
    }

    pub fn set_parent(&mut self, parent: Option<EntityID>, child: EntityID) -> bool {
        self.world.set_parent(parent, child)
    }

    #[inline]
    pub fn parent(&self, entity: EntityID) -> Option<EntityID> {
        self.world.parent(entity)
    }

    #[inline]
    pub fn children(&self, entity: EntityID) -> Vec<EntityID> {
        self.world.children(entity)
    }

    pub fn resource<R: Send + Sync + Clone + 'static>(&self) -> Option<R> {
        self.world.resource::<R>()
    }

    pub fn set_resource<R: Send + Sync + Clone + 'static>(&mut self, resource: R) {
        self.world.set_resource(resource);
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

    // MARK: - Commands

    pub fn enqueue_destroy_entity(&mut self, entity: EntityID) {
        self.command_buffer.destroy_entity(entity);
    }

    pub fn enqueue_set_parent(&mut self, parent: Option<EntityID>, child: EntityID) {
        self.command_buffer.set_parent(parent, child);
    }

    pub fn enqueue_set_local_transform(&mut self, transform: LocalTransform, entity: EntityID) {
        self.command_buffer.set_local_transform(transform, entity);
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
        self.world
            .update_component::<crate::physics::rigid_body::RigidBody>(entity, |body| {
                body.accumulated_force += force;
                if wake {
                    body.is_sleeping = false;
                }
            })
    }

    pub fn apply_torque(
        &mut self,
        torque: diffuse_math::simd::simd_compat::Float3,
        entity: EntityID,
        wake: bool,
    ) -> bool {
        self.world
            .update_component::<crate::physics::rigid_body::RigidBody>(entity, |body| {
                body.accumulated_torque += torque;
                if wake {
                    body.is_sleeping = false;
                }
            })
    }

    pub fn apply_linear_impulse(
        &mut self,
        impulse: diffuse_math::simd::simd_compat::Float3,
        entity: EntityID,
        wake: bool,
    ) -> bool {
        self.world
            .update_component::<crate::physics::rigid_body::RigidBody>(entity, |body| {
                body.accumulated_linear_impulse += impulse;
                if wake {
                    body.is_sleeping = false;
                }
            })
    }

    pub fn apply_angular_impulse(
        &mut self,
        impulse: diffuse_math::simd::simd_compat::Float3,
        entity: EntityID,
        wake: bool,
    ) -> bool {
        self.world
            .update_component::<crate::physics::rigid_body::RigidBody>(entity, |body| {
                body.accumulated_angular_impulse += impulse;
                if wake {
                    body.is_sleeping = false;
                }
            })
    }

    // MARK: - Schedule access

    #[inline]
    pub fn schedule(&self) -> &RuntimeWorldSchedule {
        &self.schedule
    }

    #[inline]
    pub fn schedule_mut(&mut self) -> &mut RuntimeWorldSchedule {
        &mut self.schedule
    }

    pub fn set_script_driver(&mut self, driver: Box<dyn crate::scripting::RuntimeScriptDriver>) {
        self.schedule.set_script_driver(driver);
    }

    pub fn clear_script_driver(&mut self) {
        self.schedule.clear_script_driver();
    }
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
