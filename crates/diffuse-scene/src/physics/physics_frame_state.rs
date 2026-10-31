//! Per-frame physics clocks, counters and the state-hash frame result.
//!
//! These are frame resources: Swift declares no `Codable` conformance on any of
//! them, so MIGRATION.md §5.4 does not apply and the `Double` fields stay plain
//! `f64` rather than going through the Swift-compatible float formatter.

use crate::physics::backend::physics_backend_capabilities::PhysicsBackendCapabilities;
use crate::physics::physics_types::PhysicsBackendError;

/// `PhysicsStepClockResource` — fixed-step accumulator bookkeeping.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhysicsStepClockResource {
    pub accumulated_seconds: f64,
    pub simulated_steps: i64,
    pub last_step_count: i64,
    pub last_stepped_seconds: f64,
    pub dropped_steps: i64,
    pub last_dropped_step_count: i64,
}

impl PhysicsStepClockResource {
    pub fn new(
        accumulated_seconds: f64,
        simulated_steps: i64,
        last_step_count: i64,
        last_stepped_seconds: f64,
        dropped_steps: i64,
        last_dropped_step_count: i64,
    ) -> Self {
        PhysicsStepClockResource {
            accumulated_seconds,
            simulated_steps,
            last_step_count,
            last_stepped_seconds,
            dropped_steps,
            last_dropped_step_count,
        }
    }
}

/// Authored bodies the backend actually simulated this frame.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhysicsFrameBodyCounts {
    pub total: i64,
    pub soft: i64,
    pub soft_vertices: i64,
    pub constraints: i64,
    pub contacts: i64,
    pub writebacks: i64,
}

impl PhysicsFrameBodyCounts {
    pub fn new(
        total: i64,
        soft: i64,
        soft_vertices: i64,
        constraints: i64,
        contacts: i64,
        writebacks: i64,
    ) -> Self {
        PhysicsFrameBodyCounts {
            total,
            soft,
            soft_vertices,
            constraints,
            contacts,
            writebacks,
        }
    }
}

/// Entities synchronized from the simulation back into the scene this frame.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PhysicsFrameSynchronization {
    pub bodies: i64,
    pub soft_bodies: i64,
    pub constraints: i64,
    /// Time spent copying simulation state into scene storage.
    pub nanoseconds: u64,
}

impl PhysicsFrameSynchronization {
    pub fn new(bodies: i64, soft_bodies: i64, constraints: i64, nanoseconds: u64) -> Self {
        PhysicsFrameSynchronization {
            bodies,
            soft_bodies,
            constraints,
            nanoseconds,
        }
    }
}

/// `PhysicsFrameStateResource`.
#[derive(Clone, Debug, PartialEq)]
pub struct PhysicsFrameStateResource {
    pub backend_identifier: String,
    pub counts: PhysicsFrameBodyCounts,
    pub synchronization: PhysicsFrameSynchronization,
    pub simulated_steps: i64,
    pub simulated_seconds: f64,
    pub active_body_count: i64,
    pub active_soft_body_count: i64,
    pub dropped_step_count: i64,
    pub step_nanoseconds: u64,
    pub last_error: Option<PhysicsBackendError>,
    /// Authored features the active backend cannot simulate.
    pub unsupported_features: PhysicsBackendCapabilities,
}

impl PhysicsFrameStateResource {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        backend_identifier: impl Into<String>,
        counts: PhysicsFrameBodyCounts,
        synchronization: PhysicsFrameSynchronization,
        simulated_steps: i64,
        simulated_seconds: f64,
        active_body_count: i64,
        active_soft_body_count: i64,
        dropped_step_count: i64,
        step_nanoseconds: u64,
        last_error: Option<PhysicsBackendError>,
        unsupported_features: PhysicsBackendCapabilities,
    ) -> Self {
        PhysicsFrameStateResource {
            backend_identifier: backend_identifier.into(),
            counts,
            synchronization,
            simulated_steps,
            simulated_seconds,
            active_body_count,
            active_soft_body_count,
            dropped_step_count,
            step_nanoseconds,
            last_error,
            unsupported_features,
        }
    }
}

impl Default for PhysicsFrameStateResource {
    /// Swift's memberwise defaults: identifier `"none"`, every counter at zero and
    /// no unsupported features.
    fn default() -> Self {
        PhysicsFrameStateResource {
            backend_identifier: "none".to_string(),
            counts: PhysicsFrameBodyCounts::default(),
            synchronization: PhysicsFrameSynchronization::default(),
            simulated_steps: 0,
            simulated_seconds: 0.0,
            active_body_count: 0,
            active_soft_body_count: 0,
            dropped_step_count: 0,
            step_nanoseconds: 0,
            last_error: None,
            unsupported_features: PhysicsBackendCapabilities::new(0),
        }
    }
}

/// `PhysicsStateHashFrameResource` — the determinism probe published per step.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PhysicsStateHashFrameResource {
    pub simulated_step: i64,
    pub hash: u64,
}

impl PhysicsStateHashFrameResource {
    pub fn new(simulated_step: i64, hash: u64) -> Self {
        PhysicsStateHashFrameResource {
            simulated_step,
            hash,
        }
    }

    /// `static let empty`.
    pub fn empty() -> Self {
        PhysicsStateHashFrameResource::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_state_defaults_match_swift_memberwise_defaults() {
        let state = PhysicsFrameStateResource::default();
        assert_eq!(state.backend_identifier, "none");
        assert_eq!(state.counts, PhysicsFrameBodyCounts::default());
        assert_eq!(
            state.synchronization,
            PhysicsFrameSynchronization::default()
        );
        assert_eq!(state.simulated_steps, 0);
        assert_eq!(state.simulated_seconds, 0.0);
        assert_eq!(state.step_nanoseconds, 0);
        assert_eq!(state.last_error, None);
        assert_eq!(
            state.unsupported_features,
            PhysicsBackendCapabilities::new(0)
        );
    }

    #[test]
    fn state_hash_empty_is_zeroed() {
        let empty = PhysicsStateHashFrameResource::empty();
        assert_eq!(empty.simulated_step, 0);
        assert_eq!(empty.hash, 0);
        assert_eq!(empty, PhysicsStateHashFrameResource::new(0, 0));
    }
}
