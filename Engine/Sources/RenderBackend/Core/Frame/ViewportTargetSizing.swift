/// Grows immediately and reclaims a substantially oversized allocation once
/// the requested extent has settled. Retained surface leases keep old frames valid.
public struct ViewportTargetSizing: Sendable {
    public static let settleInterval: Double = 1
    private var candidate: RenderDrawableSize?
    private var candidateSince: Double = 0

    public init() {}

    public mutating func capacity(current: RenderDrawableSize,
                                  used: RenderDrawableSize,
                                  now: Double) -> RenderDrawableSize {
        let used = ViewportTargetAllocation.clampedUsed(used)
        let grown = ViewportTargetAllocation.grownCapacity(current: current, used: used)
        guard grown == current else { candidate = nil; return grown }
        let compact = ViewportTargetAllocation.grownCapacity(
            current: RenderDrawableSize(width: 0, height: 0), used: used)
        let area = UInt64(current.width) * UInt64(current.height)
        let compactArea = UInt64(compact.width) * UInt64(compact.height)
        guard compactArea * 4 <= area, compact != current, now.isFinite else {
            candidate = nil
            return current
        }
        if candidate != compact || now < candidateSince {
            candidate = compact
            candidateSince = now
            return current
        }
        guard now - candidateSince >= Self.settleInterval else { return current }
        candidate = nil
        return compact
    }
}
