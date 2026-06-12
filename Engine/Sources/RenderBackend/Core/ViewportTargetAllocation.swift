/// Grow-only allocation policy for offscreen frame-graph targets.
///
/// Targets are allocated at a quantized capacity and the frame renders into
/// the top-left `used` sub-region, so dragging a panel splitter never
/// recreates textures mid-resize. Capacity only grows; shrinking requires an
/// explicit reset (renderer teardown).
public enum ViewportTargetAllocation {
    public static let granularity: UInt32 = 256
    public static let maxDimension: UInt32 = 16_384

    public static func quantized(_ value: UInt32) -> UInt32 {
        let clamped = min(max(value, 1), maxDimension)
        let rounded = (clamped + granularity - 1) / granularity * granularity
        return min(rounded, maxDimension)
    }

    /// Capacity that fits `used`, reusing `current` when it is already large
    /// enough in both dimensions.
    public static func grownCapacity(current: RenderDrawableSize,
                                     used: RenderDrawableSize) -> RenderDrawableSize {
        if current.width >= used.width, current.height >= used.height,
           current.width > 0, current.height > 0 {
            return current
        }
        return RenderDrawableSize(
            width: max(current.width, quantized(used.width)),
            height: max(current.height, quantized(used.height))
        )
    }

    /// Rendered extent clamped to hardware-safe bounds.
    public static func clampedUsed(_ size: RenderDrawableSize) -> RenderDrawableSize {
        RenderDrawableSize(width: min(max(size.width, 1), maxDimension),
                           height: min(max(size.height, 1), maxDimension))
    }
}
