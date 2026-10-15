/// One target and the timing used to reach it from the previous keyframe.
public struct AnimationKeyframe<Value: Interpolatable> {
    let value: Value
    let animation: Animation
    public init(_ value: Value, duration: Double, curve: AnimationCurve = .linear) {
        precondition(duration.isFinite && duration > 0, "Keyframe durations must be finite and positive")
        self.value = value; animation = Animation(duration: duration, curve: curve, allowsOvershoot: true)
    }
}

/// An immutable track with explicit targets. Sampling is independent of frame
/// cadence; a large tick can cross any number of segments without losing time.
public struct KeyframeTimeline<Value: Interpolatable> {
    public let initialValue: Value
    private let keyframes: [AnimationKeyframe<Value>]
    private let ends: [Double]
    public var duration: Double { ends.last ?? 0 }
    private var finalValue: Value { keyframes.last?.value ?? initialValue }

    public init(initialValue: Value, keyframes: [AnimationKeyframe<Value>]) {
        precondition(!keyframes.isEmpty, "A timeline requires a keyframe")
        self.initialValue = initialValue; self.keyframes = keyframes
        var total = 0.0
        ends = keyframes.map { total += $0.animation.duration; return total }
        precondition(total.isFinite, "Timeline duration must be finite")
    }

    public func value(at time: Double) -> Value {
        if time.isNaN || time <= 0 { return initialValue }
        if time >= duration { return finalValue }
        var lower = 0, upper = ends.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ends[middle] <= time { lower = middle + 1 } else { upper = middle }
        }
        let segment = keyframes[lower], startTime = lower == 0 ? 0 : ends[lower - 1]
        let start = lower == 0 ? initialValue : keyframes[lower - 1].value
        let progress = segment.animation.curve.evaluate(Float((time - startTime) / segment.animation.duration))
        return Value.interpolate(start, segment.value, t: progress)
    }
}
