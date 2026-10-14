/// A normalized piecewise linear timing curve. Construction validates the
/// authored points once; evaluation locates a segment in O(log n).
public struct LinearTimingCurve: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public let time: Float
        public let progress: Float
        public init(time: Float, progress: Float) { self.time = time; self.progress = progress }
    }

    private let points: [Point]

    /// Points must have finite coordinates, strictly increasing times, and
    /// anchors `(0, 0)` and `(1, 1)`. Interior progress can overshoot or reverse.
    public init(_ points: [Point]) {
        precondition(points.count >= 2, "A linear timing curve requires at least two points")
        precondition(points.first == Point(time: 0, progress: 0) && points.last == Point(time: 1, progress: 1),
                     "A linear timing curve must start at (0, 0) and end at (1, 1)")
        precondition(points.allSatisfy { $0.time.isFinite && $0.progress.isFinite }
            && zip(points, points.dropFirst()).allSatisfy { $0.time < $1.time },
            "Linear timing points must be finite and strictly ordered by time")
        self.points = points
    }

    func evaluate(_ time: Float) -> Float {
        if time <= 0 { return 0 }
        if time >= 1 { return 1 }
        var lower = 0, upper = points.count - 1
        while upper - lower > 1 {
            let middle = lower + (upper - lower) / 2
            if points[middle].time <= time { lower = middle } else { upper = middle }
        }
        let first = points[lower], last = points[upper]
        // Double intermediates preserve finite interpolation even when two
        // valid Float progress values have a difference larger than Float.max.
        let fraction = (Double(time) - Double(first.time)) / (Double(last.time) - Double(first.time))
        return Float(Double(first.progress) + (Double(last.progress) - Double(first.progress)) * fraction)
    }
}
