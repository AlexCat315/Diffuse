//! Grow-only allocation policy for offscreen frame-graph targets.
//!
//! Ported from
//! `Engine/Sources/RenderBackend/Core/Frame/ViewportTargetAllocation.swift`.
//!
//! Targets are allocated at a quantized capacity and the frame renders into
//! the top-left `used` sub-region, so dragging a panel splitter never
//! recreates textures mid-resize. Capacity only grows; shrinking requires an
//! explicit reset (renderer teardown).

use super::render_packet::RenderDrawableSize;

pub enum ViewportTargetAllocation {}

impl ViewportTargetAllocation {
    pub const GRANULARITY: u32 = 256;
    pub const MAX_DIMENSION: u32 = 16_384;

    pub fn quantized(value: u32) -> u32 {
        let clamped = value.clamp(1, Self::MAX_DIMENSION);
        let rounded = (clamped + Self::GRANULARITY - 1) / Self::GRANULARITY * Self::GRANULARITY;
        rounded.min(Self::MAX_DIMENSION)
    }

    /// Capacity that fits `used`, reusing `current` when it is already large
    /// enough in both dimensions.
    pub fn grown_capacity(
        current: RenderDrawableSize,
        used: RenderDrawableSize,
    ) -> RenderDrawableSize {
        if current.width >= used.width
            && current.height >= used.height
            && current.width > 0
            && current.height > 0
        {
            return current;
        }
        RenderDrawableSize::new(
            current.width.max(Self::quantized(used.width)),
            current.height.max(Self::quantized(used.height)),
        )
    }

    /// Rendered extent clamped to hardware-safe bounds.
    pub fn clamped_used(size: RenderDrawableSize) -> RenderDrawableSize {
        RenderDrawableSize::new(
            size.width.clamp(1, Self::MAX_DIMENSION),
            size.height.clamp(1, Self::MAX_DIMENSION),
        )
    }
}
