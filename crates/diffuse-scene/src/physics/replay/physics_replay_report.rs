/// Whether the schedule is currently replaying a recorded command tape.
///
/// While replaying, scripts are skipped: the tape owns the world's physics input,
/// so a script writing the same channels would corrupt the replay.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PhysicsCommandReplayControlResource {
    pub is_replaying: bool,
}

impl PhysicsCommandReplayControlResource {
    pub fn new(is_replaying: bool) -> Self {
        PhysicsCommandReplayControlResource { is_replaying }
    }
}

#[cfg(test)]
mod replay_control_tests {
    use super::*;

    #[test]
    fn a_fresh_control_resource_is_not_replaying() {
        assert!(!PhysicsCommandReplayControlResource::default().is_replaying);
    }

    #[test]
    fn the_replaying_flag_is_carried() {
        assert!(PhysicsCommandReplayControlResource::new(true).is_replaying);
    }
}

/// One frame whose replay did not reproduce the recorded checkpoint.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PhysicsReplayMismatch {
    pub frame_index: usize,
    pub expected_simulated_step: i64,
    pub actual_simulated_step: i64,
    pub expected_state_hash: u64,
    pub actual_state_hash: u64,
}

impl PhysicsReplayMismatch {
    pub fn new(
        frame_index: usize,
        expected_simulated_step: i64,
        actual_simulated_step: i64,
        expected_state_hash: u64,
        actual_state_hash: u64,
    ) -> Self {
        PhysicsReplayMismatch {
            frame_index,
            expected_simulated_step,
            actual_simulated_step,
            expected_state_hash,
            actual_state_hash,
        }
    }
}

/// The outcome of replaying a whole tape.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PhysicsReplayReport {
    pub replayed_frame_count: usize,
    pub checkpoint_hashes: Vec<u64>,
    pub mismatches: Vec<PhysicsReplayMismatch>,
}

impl PhysicsReplayReport {
    pub fn new(
        replayed_frame_count: usize,
        checkpoint_hashes: Vec<u64>,
        mismatches: Vec<PhysicsReplayMismatch>,
    ) -> Self {
        PhysicsReplayReport {
            replayed_frame_count,
            checkpoint_hashes,
            mismatches,
        }
    }

    /// True when every replayed frame reproduced its recorded hash.
    #[inline]
    pub fn is_deterministic(&self) -> bool {
        self.mismatches.is_empty()
    }
}

#[cfg(test)]
mod replay_report_tests {
    use super::*;

    #[test]
    fn a_report_without_mismatches_is_deterministic() {
        let report = PhysicsReplayReport::new(3, vec![1, 2, 3], Vec::new());
        assert!(report.is_deterministic());
        assert_eq!(report.replayed_frame_count, 3);
    }

    #[test]
    fn a_single_mismatch_breaks_determinism() {
        let report =
            PhysicsReplayReport::new(1, vec![7], vec![PhysicsReplayMismatch::new(0, 4, 5, 7, 9)]);
        assert!(!report.is_deterministic());
    }
}
