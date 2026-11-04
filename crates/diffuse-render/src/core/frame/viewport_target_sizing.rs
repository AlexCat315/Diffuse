//! Grows immediately and reclaims a substantially oversized allocation once
//! the requested extent has settled. Retained surface leases keep old frames
//! valid.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/Frame/ViewportTargetSizing.swift`.

use super::render_packet::RenderDrawableSize;
use super::viewport_target_allocation::ViewportTargetAllocation;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ViewportTargetSizing {
    candidate: Option<RenderDrawableSize>,
    candidate_since: f64,
}

impl ViewportTargetSizing {
    pub const SETTLE_INTERVAL: f64 = 1.0;

    pub fn new() -> Self {
        ViewportTargetSizing {
            candidate: None,
            candidate_since: 0.0,
        }
    }

    pub fn capacity(
        &mut self,
        current: RenderDrawableSize,
        used: RenderDrawableSize,
        now: f64,
    ) -> RenderDrawableSize {
        let used = ViewportTargetAllocation::clamped_used(used);
        let grown = ViewportTargetAllocation::grown_capacity(current, used);
        if grown != current {
            self.candidate = None;
            return grown;
        }
        let compact = ViewportTargetAllocation::grown_capacity(RenderDrawableSize::new(0, 0), used);
        let area = u64::from(current.width) * u64::from(current.height);
        let compact_area = u64::from(compact.width) * u64::from(compact.height);
        if compact_area * 4 > area || compact == current || !now.is_finite() {
            self.candidate = None;
            return current;
        }
        if self.candidate != Some(compact) || now < self.candidate_since {
            self.candidate = Some(compact);
            self.candidate_since = now;
            return current;
        }
        if now - self.candidate_since < Self::SETTLE_INTERVAL {
            return current;
        }
        self.candidate = None;
        compact
    }
}

impl Default for ViewportTargetSizing {
    fn default() -> Self {
        Self::new()
    }
}
