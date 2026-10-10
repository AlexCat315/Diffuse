import Foundation

/// Estimates how fast, along one axis, the user is scrolling — in points per
/// second — from a stream of position samples.
///
/// Wheel notches arrive at irregular intervals and each one travels a
/// different distance, so `delta / deltaTime` taken between the last two
/// events is unusably jittery: one notch that lands slightly late reads as
/// half speed, and a trackpad emits dozens of unequal deltas per second.
/// UIKit and Android both fit a line across a short window of samples instead.
/// That is what this does.
///
/// One instance per axis — a scroll container keeps two, one for each.
public struct ScrollVelocityTracker: Sendable, Equatable {

    /// How far back recorded samples contribute, in seconds. Short enough to
    /// follow a deliberate change of direction, long enough for the fit to
    /// smooth estimator noise out.
    public var window: TimeInterval

    private struct Sample: Sendable, Equatable {
        let time: TimeInterval
        let value: Float
    }

    /// Oldest samples are dropped first; the cap keeps a runaway 1000 Hz
    /// wheel device from growing the window without bound between trims.
    private static let maximumSampleCount = 16

    private var samples: [Sample] = []

    public init(window: TimeInterval = 0.1) {
        self.window = window
    }

    /// Number of samples retained right now. Useful when deciding whether a
    /// velocity means anything.
    public var sampleCount: Int { samples.count }

    /// Drop everything recorded so far — call when a gesture begins so a
    /// flick cannot be launched from samples belonging to the previous one.
    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// Record where the content was at `time`.
    ///
    /// `value` is a *position*, not a delta. Fitting the line against
    /// positions keeps the estimate independent of how the interval between
    /// two events happened to be split, so merging or dropping one event does
    /// not change the answer.
    public mutating func add(time: TimeInterval, value: Float) {
        guard time.isFinite, value.isFinite else { return }
        if let last = samples.last, time < last.time {
            // The clock went backwards — a host resume, or an injected test
            // clock. Everything recorded belongs to a timeline we can no
            // longer measure against, so start over.
            reset()
        }
        samples.append(Sample(time: time, value: value))
        trim(to: time)
    }

    /// Least-squares slope of the retained samples, in points per second.
    ///
    /// Samples are aged against the *newest one*, not against `time`: whatever
    /// lies between the last sample and now is silence by definition, so
    /// measuring across it would report the pause rather than the gesture.
    ///
    /// Returns `0` when there is nothing usable to fit: a single sample
    /// carries no direction, and a gesture that stopped moving has genuinely
    /// come to rest.
    ///
    /// - Parameters:
    ///   - time: "now", used only to decide whether the samples are stale.
    ///   - staleAfter: age past which the newest sample is treated as the end
    ///     of a gesture that has already stopped, and no velocity is reported.
    public mutating func velocity(at time: TimeInterval? = nil,
                                  staleAfter: TimeInterval? = nil) -> Float {
        guard let newest = samples.last?.time else { return 0 }
        if let staleAfter, let now = time, now - newest > staleAfter { return 0 }
        trim(to: newest)
        guard samples.count >= 2 else { return 0 }

        let count = Double(samples.count)
        let meanTime = samples.reduce(0) { $0 + $1.time } / count
        let meanValue = samples.reduce(0) { $0 + Double($1.value) } / count

        var numerator = 0.0
        var denominator = 0.0
        for sample in samples {
            let elapsed = sample.time - meanTime
            numerator += elapsed * (Double(sample.value) - meanValue)
            denominator += elapsed * elapsed
        }
        // All samples share one timestamp (a burst in the same millisecond) —
        // there is a position but no measurable rate.
        guard denominator > 0 else { return 0 }
        let slope = numerator / denominator
        guard slope.isFinite else { return 0 }
        return Float(slope)
    }

    private mutating func trim(to time: TimeInterval) {
        guard time.isFinite else { return }
        let cutoff = time - max(0, window)
        samples.removeAll { $0.time < cutoff }
        if samples.count > Self.maximumSampleCount {
            samples.removeFirst(samples.count - Self.maximumSampleCount)
        }
    }
}
