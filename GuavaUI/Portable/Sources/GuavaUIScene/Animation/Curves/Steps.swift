import Foundation
#if os(Android)
import Android
#endif

public enum AnimationStepPosition: Sendable, Equatable {
    /// The first jump occurs at time zero.
    case start
    /// The last jump occurs at time one.
    case end
}

extension AnimationCurve {
    static func evaluateSteps(x: Float, count: Int, position: AnimationStepPosition) -> Float {
        let intervals = Float(max(1, count))
        let step = floor(x * intervals) + (position == .start ? 1 : 0)
        return max(0, min(1, step / intervals))
    }
}
