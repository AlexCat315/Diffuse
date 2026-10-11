/// Pane minimums use logical points. When they cannot both fit, the available
/// space is shared in proportion to those minimums; neither pane overflows.
public struct SplitConstraints: Sendable, Equatable {
    public var fraction: ClosedRange<Float> = 0.1...0.9
    public var minimumFirst: Float = 0
    public var minimumSecond: Float = 0

    public init(fraction: ClosedRange<Float> = 0.1...0.9,
                minimumFirst: Float = 0, minimumSecond: Float = 0) {
        self.fraction = fraction
        self.minimumFirst = minimumFirst
        self.minimumSecond = minimumSecond
    }

    public func range(available: Float) -> ClosedRange<Float> {
        let lower = max(0, min(1, fraction.lowerBound.isFinite ? fraction.lowerBound : 0.1))
        let upper = max(lower, min(1, fraction.upperBound.isFinite ? fraction.upperBound : 0.9))
        guard available.isFinite, available > 0 else { return lower...upper }
        let first = minimumFirst.isFinite ? max(0, minimumFirst) : 0
        let second = minimumSecond.isFinite ? max(0, minimumSecond) : 0
        if first + second >= available, first + second > 0 {
            let share = first / (first + second)
            return share...share
        }
        let feasible = (first / available)...(1 - second / available)
        let constrainedLow = max(lower, feasible.lowerBound)
        let constrainedHigh = min(upper, feasible.upperBound)
        return constrainedLow <= constrainedHigh ? constrainedLow...constrainedHigh : feasible
    }
}
