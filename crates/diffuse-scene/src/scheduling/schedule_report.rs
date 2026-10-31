//! Per-frame schedule reports: command, physics and job accounting.
//!
//! Every struct here is a plain observable value whose groups own their own
//! defaults, so a caller can build a partial report without naming every field —
//! the same shape Swift's defaulted initializers provided.

use std::collections::BTreeMap;

use crate::entity_id::EntityID;
use crate::physics::physics_types::PhysicsBackendError;
use crate::scheduling::schedule_commands::RuntimeSystemPhase;

/// Command-buffer outcome of one `RuntimeWorldSchedule.run` call.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScheduleCommandReport {
    pub applied_count: usize,
    pub created_entities: Vec<EntityID>,
    pub destroyed_entities: Vec<EntityID>,
}

impl ScheduleCommandReport {
    #[inline]
    pub fn new() -> Self {
        ScheduleCommandReport::default()
    }
}

/// Physics counters and timings of one `RuntimeWorldSchedule.run` call.
///
/// Timings are nanoseconds accumulated across every substep of the frame; counters
/// describe the descriptors and results that reached the backend.
#[derive(Clone, Debug, PartialEq)]
pub struct SchedulePhysicsReport {
    pub step_count: usize,
    pub writeback_count: usize,
    pub body_count: usize,
    pub soft_body_count: usize,
    pub soft_body_vertex_count: usize,
    pub constraint_count: usize,
    pub contact_count: usize,
    pub backend_identifier: String,
    pub synchronization_nanoseconds: u64,
    pub step_nanoseconds: u64,
    pub dropped_step_count: usize,
    pub error: Option<PhysicsBackendError>,
}

impl SchedulePhysicsReport {
    /// Swift's default-argument initializer, including `backendIdentifier: "none"`.
    pub fn new() -> Self {
        SchedulePhysicsReport {
            step_count: 0,
            writeback_count: 0,
            body_count: 0,
            soft_body_count: 0,
            soft_body_vertex_count: 0,
            constraint_count: 0,
            contact_count: 0,
            backend_identifier: "none".to_string(),
            synchronization_nanoseconds: 0,
            step_nanoseconds: 0,
            dropped_step_count: 0,
            error: None,
        }
    }
}

impl Default for SchedulePhysicsReport {
    fn default() -> Self {
        Self::new()
    }
}

/// Job-system usage of one `RuntimeWorldSchedule.run` call.
#[derive(Clone, Debug, PartialEq)]
pub struct ScheduleJobReport {
    pub scheduled_count: usize,
    pub worker_count: usize,
    pub parallel_phases: Vec<RuntimeSystemPhase>,
    pub phase_job_counts: BTreeMap<RuntimeSystemPhase, usize>,
}

impl ScheduleJobReport {
    /// Swift defaults: `workerCount: 1`, empty phase data.
    pub fn new() -> Self {
        ScheduleJobReport {
            scheduled_count: 0,
            worker_count: 1,
            parallel_phases: Vec::new(),
            phase_job_counts: BTreeMap::new(),
        }
    }

    #[inline]
    pub fn job_count(&self, phase: RuntimeSystemPhase) -> usize {
        self.phase_job_counts.get(&phase).copied().unwrap_or(0)
    }
}

impl Default for ScheduleJobReport {
    fn default() -> Self {
        Self::new()
    }
}

/// Aggregated outcome of one `RuntimeWorldSchedule.run` call.
#[derive(Clone, Debug, PartialEq)]
pub struct RuntimeScheduleReport {
    pub phases: Vec<RuntimeSystemPhase>,
    pub commands: ScheduleCommandReport,
    pub physics: SchedulePhysicsReport,
    pub jobs: ScheduleJobReport,
    pub revision: u64,
    /// CPU duration of each complete schedule phase, including descriptor collection
    /// and writeback.
    pub phase_nanoseconds: BTreeMap<RuntimeSystemPhase, u64>,
}

impl RuntimeScheduleReport {
    pub fn new() -> Self {
        RuntimeScheduleReport {
            phases: Vec::new(),
            commands: ScheduleCommandReport::new(),
            physics: SchedulePhysicsReport::new(),
            jobs: ScheduleJobReport::new(),
            revision: 0,
            phase_nanoseconds: BTreeMap::new(),
        }
    }
}

impl Default for RuntimeScheduleReport {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn physics_report_defaults_use_the_none_identifier() {
        let report = SchedulePhysicsReport::new();
        assert_eq!(report.backend_identifier, "none");
        assert_eq!(report.step_count, 0);
        assert!(report.error.is_none());
    }

    #[test]
    fn job_report_reports_zero_for_an_unseen_phase() {
        let report = ScheduleJobReport::new();
        assert_eq!(report.worker_count, 1);
        assert_eq!(report.job_count(RuntimeSystemPhase::RenderExtract), 0);
    }

    #[test]
    fn job_report_returns_the_recorded_count() {
        let mut report = ScheduleJobReport::new();
        report
            .phase_job_counts
            .insert(RuntimeSystemPhase::FixedPhysicsStep, 4);
        assert_eq!(report.job_count(RuntimeSystemPhase::FixedPhysicsStep), 4);
    }

    #[test]
    fn the_aggregate_report_starts_empty() {
        let report = RuntimeScheduleReport::new();
        assert!(report.phases.is_empty());
        assert_eq!(report.revision, 0);
        assert!(report.phase_nanoseconds.is_empty());
        assert_eq!(report.commands.applied_count, 0);
    }
}
