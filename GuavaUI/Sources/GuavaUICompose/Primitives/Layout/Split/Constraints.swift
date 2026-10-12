/// Pane bounds use logical points. Impossible minimums share space in proportion
/// to their minimums. Maximums constrain the divider whenever both panes can
/// fill the container; if their sum is too small, surplus is shared in proportion
/// to the maximums. This keeps a filling split deterministic without overflow.
public struct SplitConstraints: Sendable, Equatable {
    public var fraction: ClosedRange<Float> = 0.1...0.9
    public var minimumFirst: Float = 0
    public var minimumSecond: Float = 0
    public var maximumFirst: Float?
    public var maximumSecond: Float?

    public init(fraction: ClosedRange<Float> = 0.1...0.9,
                minimumFirst: Float = 0, minimumSecond: Float = 0,
                maximumFirst: Float? = nil, maximumSecond: Float? = nil) {
        self.fraction = fraction
        self.minimumFirst = minimumFirst
        self.minimumSecond = minimumSecond
        self.maximumFirst = maximumFirst
        self.maximumSecond = maximumSecond
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
        let maxFirst = maximumFirst.flatMap { $0.isFinite ? max(first, $0) : nil } ?? available
        let maxSecond = maximumSecond.flatMap { $0.isFinite ? max(second, $0) : nil } ?? available
        if maxFirst + maxSecond < available {
            let proposed = maxFirst + maxSecond > 0 ? maxFirst / (maxFirst + maxSecond) : 0.5
            let share = max(first / available, min(1 - second / available, proposed))
            return share...share
        }
        let feasible = max(first / available, 1 - maxSecond / available)...min(1 - second / available, maxFirst / available)
        let constrainedLow = max(lower, feasible.lowerBound)
        let constrainedHigh = min(upper, feasible.upperBound)
        return constrainedLow <= constrainedHigh ? constrainedLow...constrainedHigh : feasible
    }
}
