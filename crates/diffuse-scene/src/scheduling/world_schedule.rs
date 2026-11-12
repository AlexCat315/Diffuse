//! `RuntimeWorldSchedule` — the ten-phase frame loop.
//!
//! The phase order is the frame's execution order and is taken from
//! `RuntimeSystemPhase::ALL`, whose declaration order is the order the phases run.
//! Every phase is timed individually and reported.
//!
//! Two invariants the loop depends on:
//!
//! - derived resources are written with `set_resource` as the phase produces them, so a
//!   phase that reads another phase's output sees this frame's value, not last frame's;
//! - the three command-frame resources are cleared **after** the revision bump, so a
//!   script that enqueues a command during `postPhysicsScripts` still has it drained by
//!   the next frame's `commandApply` and does not see it silently dropped.

use crate::physics::backend::physics_backend::PhysicsBackend;
use std::collections::BTreeMap;
use std::time::Instant;

use crate::physics::character_controller::CharacterCommandFrameResource;
use crate::physics::destruction::DestructionCommandFrameResource;
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::vehicles::vehicle_state::VehicleCommandFrameResource;
use crate::rendering::render_extraction::ExtractedRenderSceneResource;
use crate::runtime_world::RuntimeWorld;
use crate::scheduling::physics_collection::build_physics_read_view;
use crate::scheduling::schedule_commands::{RuntimeCommandBuffer, RuntimeSystemPhase};
use crate::scheduling::schedule_frame_context::RuntimeFrameContext;
use crate::scheduling::schedule_phases::{
    ScheduleState, apply_commands, build_schedule_report, detect_triggers,
    ensure_configured_physics_backend, prepare_fixed_physics, run_post_physics_scripts,
    run_pre_physics_scripts, step_fixed_physics, update_spatial_index, write_back_physics,
};
use crate::scheduling::schedule_report::RuntimeScheduleReport;

/// The schedule that owns a world's per-frame physics and scripting state.
#[derive(Clone)]
pub struct RuntimeWorldSchedule {
    state: ScheduleState,
    /// The last extracted render scene, replaced each frame by the `renderExtract` phase.
    last_render_scene: ExtractedRenderSceneResource,
}

impl RuntimeWorldSchedule {
    /// A new schedule selecting the preferred physics backend, as Swift's `init` does.
    pub fn new() -> Self {
        RuntimeWorldSchedule {
            state: ScheduleState::new(),
            last_render_scene: ExtractedRenderSceneResource::default(),
        }
    }

    pub fn set_physics_backend(
        &mut self,
        backend: Box<dyn crate::physics::backend::physics_backend::PhysicsBackend>,
    ) {
        self.state.set_physics_backend(backend);
    }

    pub fn clear_physics_backend_override(&mut self) {
        self.state.clear_physics_backend_override();
    }

    pub fn set_script_driver(
        &mut self,
        driver: impl Into<crate::scripting::SharedRuntimeScriptDriver>,
    ) {
        self.state.set_script_driver(driver);
    }

    pub fn clear_script_driver(&mut self) {
        self.state.clear_script_driver();
    }

    pub fn set_job_system(&mut self, job_system: diffuse_kernel::job_system::JobSystem) {
        self.state.job_system = job_system;
    }

    pub fn current_physics_backend_identifier(&self) -> &str {
        self.state.physics_backend.identifier()
    }

    pub fn current_physics_clock(
        &self,
    ) -> crate::physics::physics_frame_state::PhysicsStepClockResource {
        self.state.physics_clock.clone()
    }

    pub fn current_physics_frame_state(
        &self,
    ) -> crate::physics::physics_frame_state::PhysicsFrameStateResource {
        self.state.physics_frame_state.clone()
    }

    pub fn current_physics_contact_frame(
        &self,
    ) -> crate::physics::physics_events::PhysicsContactFrameResource {
        self.state.physics_contact_frame.clone()
    }

    pub fn current_physics_debug_frame(
        &self,
    ) -> crate::physics::physics_debug_frame::PhysicsDebugFrameResource {
        self.state.physics_debug_frame.clone()
    }

    pub fn current_physics_event_frame(
        &self,
    ) -> crate::physics::physics_events::PhysicsEventFrameResource {
        self.state.physics_event_frame.clone()
    }

    pub fn current_render_scene(&self) -> &ExtractedRenderSceneResource {
        &self.last_render_scene
    }

    pub fn current_physics_query_cache_stats(
        &self,
    ) -> crate::physics::backend::physics_query_scene::PhysicsQueryCacheStats {
        self.state.physics_query_scene.stats()
    }

    /// The query backend, synchronised to the world's physics revision.
    pub fn physics_query_scene(
        &self,
    ) -> crate::physics::backend::physics_query_scene::PhysicsQueryScene {
        self.state.physics_query_scene.clone()
    }

    /// The query backend, synchronised to the world's physics revision.
    pub fn physics_query_backend(
        &mut self,
        world: &RuntimeWorld,
    ) -> crate::physics::backend::physics_backend::SharedPhysicsBackend {
        self.state.physics_query_scene.backend(world)
    }

    /// Run one frame.
    pub fn run(
        &mut self,
        world: &mut RuntimeWorld,
        commands: &mut RuntimeCommandBuffer,
        delta_time_seconds: f64,
    ) -> RuntimeScheduleReport {
        let drained_commands = commands.drain();
        let applied_count = drained_commands.len();

        let mut frame = RuntimeFrameContext::new(
            world
                .resource::<PhysicsSettingsResource>()
                .unwrap_or_default(),
        );
        frame.delta_time_seconds = delta_time_seconds;
        frame.commands_applied_count = applied_count;
        // Preserve the last complete vertex stream when a render frame does not
        // accumulate enough time for a fixed step. Removed soft bodies are pruned
        // during descriptor collection.
        frame.results.soft_body_states = self.state.soft_body_state_frame.states.clone();

        let mut phase_nanoseconds: BTreeMap<RuntimeSystemPhase, u64> = BTreeMap::new();

        for phase in RuntimeSystemPhase::ALL {
            let started = Instant::now();
            match phase {
                RuntimeSystemPhase::CommandApply => {
                    apply_commands(drained_commands.clone(), world, &mut frame);
                }
                RuntimeSystemPhase::HierarchyPropagate => {
                    let report = world.propagate_transforms(&self.state.job_system);
                    frame.jobs.record(&report, phase);
                }
                RuntimeSystemPhase::InputAndPrePhysicsScripts => {
                    run_pre_physics_scripts(
                        &mut self.state,
                        world,
                        commands,
                        &mut frame,
                        delta_time_seconds,
                    );
                }
                RuntimeSystemPhase::FixedPhysicsPrepare => {
                    prepare_fixed_physics(&mut self.state, world, &mut frame, delta_time_seconds);
                }
                RuntimeSystemPhase::FixedPhysicsStep => {
                    step_fixed_physics(&mut self.state, world, &mut frame);
                }
                RuntimeSystemPhase::PhysicsWriteback => {
                    write_back_physics(&mut self.state, world, &mut frame);
                }
                RuntimeSystemPhase::PostPhysicsScripts => {
                    run_post_physics_scripts(
                        &mut self.state,
                        world,
                        commands,
                        &mut frame,
                        delta_time_seconds,
                    );
                }
                RuntimeSystemPhase::SpatialIndexUpdate => {
                    update_spatial_index(&mut self.state, world, &mut frame);
                }
                RuntimeSystemPhase::TriggerDetection => {
                    detect_triggers(&mut self.state, world, &mut frame);
                }
                RuntimeSystemPhase::RenderExtract => {
                    self.run_render_extract(world, &mut frame);
                }
            }
            phase_nanoseconds.insert(phase, started.elapsed().as_nanos() as u64);
        }

        world.advance_revision();
        // Cleared after the revision bump: a command enqueued during
        // `postPhysicsScripts` must survive into the next frame's `commandApply`.
        world.set_derived_resource(CharacterCommandFrameResource::empty());
        world.set_derived_resource(VehicleCommandFrameResource::empty());
        world.set_derived_resource(DestructionCommandFrameResource::empty());

        build_schedule_report(&self.state, world, &frame, phase_nanoseconds)
    }

    /// The `renderExtract` phase.
    ///
    /// The scene is assembled from the world's render components and recorded on the
    /// schedule, so a consumer reads it from `current_render_scene` rather than from a
    /// world resource — Swift stored it as a derived resource as well, and both are
    /// kept here because the editor reads the resource while the renderer reads the
    /// schedule.
    fn run_render_extract(&mut self, world: &mut RuntimeWorld, frame: &mut RuntimeFrameContext) {
        let scene = crate::scheduling::render_scene_extraction::extract_render_scene(
            world,
            &self.state.job_system,
        );
        frame
            .jobs
            .record(&scene.report, RuntimeSystemPhase::RenderExtract);
        world.set_derived_resource(scene.resource.clone());
        self.last_render_scene = scene.resource;
    }

    /// A physics read view for a caller outside a phase, e.g. an editor query panel.
    pub fn physics_read_view(
        &self,
        world: &RuntimeWorld,
    ) -> crate::scheduling::physics_collection::PhysicsReadView {
        build_physics_read_view(world)
    }

    /// Force the backend selection to match the world's settings before a manual step.
    pub fn ensure_backend_matches(&mut self, world: &RuntimeWorld) {
        let settings = world
            .resource::<PhysicsSettingsResource>()
            .unwrap_or_default();
        ensure_configured_physics_backend(&mut self.state, settings.backend_kind);
    }
}

impl Default for RuntimeWorldSchedule {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::core::registry::ComponentRegistry;

    fn empty_world() -> RuntimeWorld {
        RuntimeWorld::new(ComponentRegistry::new())
    }

    #[test]
    fn a_new_schedule_reports_all_ten_phases() {
        let mut world = empty_world();
        let mut commands = RuntimeCommandBuffer::new();
        let mut schedule = RuntimeWorldSchedule::new();
        let report = schedule.run(&mut world, &mut commands, 1.0 / 60.0);
        assert_eq!(report.phases, RuntimeSystemPhase::ALL.to_vec());
        assert_eq!(report.phases.len(), 10);
    }

    #[test]
    fn every_phase_is_timed() {
        let mut world = empty_world();
        let mut commands = RuntimeCommandBuffer::new();
        let mut schedule = RuntimeWorldSchedule::new();
        let report = schedule.run(&mut world, &mut commands, 1.0 / 60.0);
        assert_eq!(report.phase_nanoseconds.len(), 10);
        for phase in RuntimeSystemPhase::ALL {
            assert!(
                report.phase_nanoseconds.contains_key(&phase),
                "{phase:?} was not timed"
            );
        }
    }

    #[test]
    fn the_frame_advances_the_world_revision() {
        let mut world = empty_world();
        let before = world.revision();
        let mut commands = RuntimeCommandBuffer::new();
        let mut schedule = RuntimeWorldSchedule::new();
        let report = schedule.run(&mut world, &mut commands, 1.0 / 60.0);
        assert!(world.revision() > before);
        assert_eq!(report.revision, world.revision());
    }

    #[test]
    fn drained_commands_are_reported_as_applied() {
        let mut world = empty_world();
        let mut commands = RuntimeCommandBuffer::new();
        commands.destroy_entity(crate::entity_id::EntityID::new(99, 0));
        let mut schedule = RuntimeWorldSchedule::new();
        let report = schedule.run(&mut world, &mut commands, 1.0 / 60.0);
        assert_eq!(report.commands.applied_count, 1);
        assert!(commands.drain().is_empty(), "the buffer must be drained");
    }

    #[test]
    fn a_frame_without_physics_selection_uses_the_configured_backend() {
        let mut world = empty_world();
        let mut commands = RuntimeCommandBuffer::new();
        let mut schedule = RuntimeWorldSchedule::new();
        let report = schedule.run(&mut world, &mut commands, 1.0 / 60.0);
        assert_eq!(
            report.physics.backend_identifier,
            schedule.current_physics_backend_identifier()
        );
    }

    #[test]
    fn a_slow_frame_produces_at_most_the_substep_budget() {
        use crate::physics::physics_settings::PhysicsSettingsResource;

        let mut world = empty_world();
        let settings = PhysicsSettingsResource {
            fixed_time_step_seconds: 1.0 / 60.0,
            max_substeps_per_frame: 2,
            ..PhysicsSettingsResource::default()
        };
        world.set_resource(settings);

        let mut commands = RuntimeCommandBuffer::new();
        let mut schedule = RuntimeWorldSchedule::new();
        // One second of delta with a 1/60 step and a budget of 2.
        let report = schedule.run(&mut world, &mut commands, 1.0);
        assert!(
            report.physics.step_count <= 2,
            "the substep budget must cap the steps, got {}",
            report.physics.step_count
        );
    }
}
