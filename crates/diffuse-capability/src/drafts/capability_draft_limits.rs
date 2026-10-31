//! `CapabilityDraftLimits` — shared protocol limits used by contract generation
//! without depending on AIRuntime.

/// Shared protocol limits used by contract generation without depending on
/// AIRuntime.
pub enum CapabilityDraftLimits {}

impl CapabilityDraftLimits {
    pub const MAXIMUM_DRAFTS_PER_PLAN: usize = 100;
    pub const MAXIMUM_INPUT_BYTES: usize = 1_048_576;
    /// Five minutes.
    pub const TIME_TO_LIVE_SECONDS: f64 = 5.0 * 60.0;
}
