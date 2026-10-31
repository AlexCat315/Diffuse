//! `ReleasePhaseGate` — which capability maturity stages this process accepts.

use crate::capability_contract::ReleasePhase;
use crate::capability_descriptor::CapabilityDescriptor;

/// Controls which capability maturity stages are accessible in this process.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReleasePhaseGate {
    /// The minimum maturity that may be used.
    pub active_phase: ReleasePhase,
}

impl ReleasePhaseGate {
    /// Swift default: `.stable`.
    #[inline]
    pub fn new(active_phase: ReleasePhase) -> Self {
        ReleasePhaseGate { active_phase }
    }

    /// Whether `descriptor`'s release phase is allowed under the current gate.
    /// `disabled` is always denied; otherwise the descriptor must be at least as
    /// mature as `active_phase`.
    pub fn is_allowed(&self, descriptor: &CapabilityDescriptor) -> bool {
        descriptor.release_phase != ReleasePhase::Disabled
            && descriptor.release_phase >= self.active_phase
    }

    /// Human-readable denial reason, or `None` when the descriptor passes.
    pub fn denied_reason(&self, descriptor: &CapabilityDescriptor) -> Option<String> {
        if self.is_allowed(descriptor) {
            return None;
        }
        match descriptor.release_phase {
            ReleasePhase::Disabled => {
                Some(format!("'{}' is permanently disabled", descriptor.verb))
            }
            ReleasePhase::Experimental => Some(format!(
                "'{}' is experimental; enable the experimental gate to use it",
                descriptor.verb
            )),
            ReleasePhase::Beta => Some(format!(
                "'{}' is in beta; enable the beta gate to use it",
                descriptor.verb
            )),
            ReleasePhase::Stable => None,
        }
    }
}

impl Default for ReleasePhaseGate {
    fn default() -> Self {
        Self::new(ReleasePhase::Stable)
    }
}
