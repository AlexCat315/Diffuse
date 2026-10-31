//! Cross-phase mutable state for one `RuntimeWorldSchedule::run` call.
//!
//! Grouping the accumulators lets each phase be a self-contained method instead of
//! one function carrying dozens of locals across a ten-case switch.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_kernel::job_system::JobDispatchReport;

use crate::entity_id::EntityID;
use crate::physics::backend::physics_backend_capabilities::PhysicsBackendCapabilities;
use crate::physics::backend::physics_backend_context::{PhysicsBodyWriteback, PhysicsSyncEvent};
use crate::physics::backend::physics_descriptors::{
    PhysicsBodyDescriptor, PhysicsCharacterDescriptor, PhysicsConstraintDescriptor,
    PhysicsSoftBodyDescriptor, PhysicsVehicleDescriptor,
};
use crate::physics::character_controller::CharacterState;
use crate::physics::destruction::{DestructionCommand, DestructionEventFrameResource};
use crate::physics::physics_events::{PhysicsContactEvent, PhysicsJointBreakEvent};
use crate::physics::physics_settings::PhysicsSettingsResource;
use crate::physics::physics_types::PhysicsBackendError;
use crate::physics::replay::physics_command_tape::{
    PhysicsRecordedBodyCommand, PhysicsRecordedCharacterCommand, PhysicsRecordedVehicleCommand,
};
use crate::physics::soft_bodies::soft_body::SoftBodyMeshState;
use crate::physics::vehicles::vehicle_state::VehicleState;
use crate::scheduling::schedule_commands::RuntimeSystemPhase;

/// Physics descriptors collected during `fixedPhysicsPrepare` and consumed by the
/// step, writeback and trigger phases.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhysicsFrameDescriptors {
    pub bodies: Vec<PhysicsBodyDescriptor>,
    pub constraints: Vec<PhysicsConstraintDescriptor>,
    pub characters: Vec<PhysicsCharacterDescriptor>,
    pub vehicles: Vec<PhysicsVehicleDescriptor>,
    pub soft_bodies: Vec<PhysicsSoftBodyDescriptor>,
}

/// Simulation output produced by `fixedPhysicsStep`, published by `physicsWriteback`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhysicsFrameResults {
    pub sync_events: Vec<PhysicsSyncEvent>,
    pub writebacks: Vec<PhysicsBodyWriteback>,
    pub contact_events: Vec<PhysicsContactEvent>,
    pub joint_break_events: Vec<PhysicsJointBreakEvent>,
    pub character_states: BTreeMap<EntityID, CharacterState>,
    pub vehicle_states: BTreeMap<EntityID, VehicleState>,
    pub soft_body_states: BTreeMap<EntityID, SoftBodyMeshState>,
}

/// Counters and timings surfaced through `RuntimeScheduleReport`.
#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsFrameMetrics {
    pub step_count: usize,
    pub writeback_count: usize,
    pub body_count: usize,
    pub soft_body_count: usize,
    pub constraint_count: usize,
    pub contact_count: usize,
    pub synchronization_nanoseconds: u64,
    pub step_nanoseconds: u64,
    pub synchronized_body_count: usize,
    pub synchronized_soft_body_count: usize,
    pub synchronized_constraint_count: usize,
    pub error: Option<PhysicsBackendError>,
    pub unsupported_features: PhysicsBackendCapabilities,
}

impl PhysicsFrameMetrics {
    /// Swift's memberwise defaults: all counters zero, no error, empty capability set.
    pub fn new() -> Self {
        PhysicsFrameMetrics {
            step_count: 0,
            writeback_count: 0,
            body_count: 0,
            soft_body_count: 0,
            constraint_count: 0,
            contact_count: 0,
            synchronization_nanoseconds: 0,
            step_nanoseconds: 0,
            synchronized_body_count: 0,
            synchronized_soft_body_count: 0,
            synchronized_constraint_count: 0,
            error: None,
            unsupported_features: PhysicsBackendCapabilities::new(0),
        }
    }
}

impl Default for PhysicsFrameMetrics {
    fn default() -> Self {
        Self::new()
    }
}

/// Commands captured for physics determinism recording and replay.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhysicsFrameRecording {
    pub body_commands: Vec<PhysicsRecordedBodyCommand>,
    pub character_commands: Vec<PhysicsRecordedCharacterCommand>,
    pub vehicle_commands: Vec<PhysicsRecordedVehicleCommand>,
    pub destruction_commands: Vec<DestructionCommand>,
    pub destruction_events: DestructionEventFrameResource,
}

/// Job-system usage accumulated across all phases.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct JobFrameStats {
    pub scheduled_job_count: usize,
    pub parallel_phases: BTreeSet<RuntimeSystemPhase>,
    pub phase_job_counts: BTreeMap<RuntimeSystemPhase, usize>,
}

impl JobFrameStats {
    pub fn new() -> Self {
        JobFrameStats::default()
    }

    /// Accumulates one phase's dispatch report. A phase that ran no jobs is not
    /// recorded, matching Swift's `guard report.jobCount > 0 else { return }`.
    pub fn record(&mut self, report: &JobDispatchReport, phase: RuntimeSystemPhase) {
        if report.job_count == 0 {
            return;
        }
        self.scheduled_job_count += report.job_count;
        *self.phase_job_counts.entry(phase).or_insert(0) += report.job_count;
        if report.executed_in_parallel {
            self.parallel_phases.insert(phase);
        }
    }
}

/// Per-frame schedule state. Swift's `RuntimeFrameContext` carried these as plain
/// `var` fields; here they are owned and reset by construction.
pub struct RuntimeFrameContext {
    /// The frame's delta, carried so phases do not each take it as a parameter.
    pub delta_time_seconds: f64,
    /// How many commands the command phase actually applied.
    pub commands_applied_count: usize,
    pub created_entities: Vec<EntityID>,
    pub destroyed_entities: Vec<EntityID>,
    pub physics_settings: PhysicsSettingsResource,
    pub descriptors: PhysicsFrameDescriptors,
    pub results: PhysicsFrameResults,
    pub metrics: PhysicsFrameMetrics,
    pub recording: PhysicsFrameRecording,
    pub jobs: JobFrameStats,
}

impl RuntimeFrameContext {
    pub fn new(physics_settings: PhysicsSettingsResource) -> Self {
        RuntimeFrameContext {
            delta_time_seconds: 0.0,
            commands_applied_count: 0,
            created_entities: Vec::new(),
            destroyed_entities: Vec::new(),
            physics_settings,
            descriptors: PhysicsFrameDescriptors::default(),
            results: PhysicsFrameResults::default(),
            metrics: PhysicsFrameMetrics::new(),
            recording: PhysicsFrameRecording::default(),
            jobs: JobFrameStats::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report(
        job_count: usize,
        worker_count: usize,
        executed_in_parallel: bool,
    ) -> JobDispatchReport {
        JobDispatchReport::new(job_count, worker_count, executed_in_parallel)
    }

    #[test]
    fn job_stats_ignore_phases_that_ran_no_jobs() {
        let mut stats = JobFrameStats::new();
        stats.record(&report(0, 4, true), RuntimeSystemPhase::CommandApply);
        assert_eq!(stats.scheduled_job_count, 0);
        assert!(stats.phase_job_counts.is_empty());
        assert!(stats.parallel_phases.is_empty());
    }

    #[test]
    fn job_stats_accumulate_counts_and_parallel_phases() {
        let mut stats = JobFrameStats::new();
        stats.record(&report(3, 4, true), RuntimeSystemPhase::FixedPhysicsStep);
        stats.record(&report(2, 4, false), RuntimeSystemPhase::RenderExtract);
        assert_eq!(stats.scheduled_job_count, 5);
        assert_eq!(
            stats.phase_job_counts[&RuntimeSystemPhase::FixedPhysicsStep],
            3
        );
        assert_eq!(
            stats.phase_job_counts[&RuntimeSystemPhase::RenderExtract],
            2
        );
        assert_eq!(
            stats.parallel_phases.iter().copied().collect::<Vec<_>>(),
            vec![RuntimeSystemPhase::FixedPhysicsStep]
        );
    }

    #[test]
    fn metrics_start_with_no_error_and_no_unsupported_features() {
        let metrics = PhysicsFrameMetrics::new();
        assert!(metrics.error.is_none());
        assert!(metrics.unsupported_features.is_empty());
        assert_eq!(metrics.step_count, 0);
    }

    #[test]
    fn a_new_frame_context_is_empty() {
        let context = RuntimeFrameContext::new(PhysicsSettingsResource::default());
        assert!(context.created_entities.is_empty());
        assert!(context.descriptors.bodies.is_empty());
        assert!(context.results.writebacks.is_empty());
        assert_eq!(context.jobs.scheduled_job_count, 0);
    }
}
