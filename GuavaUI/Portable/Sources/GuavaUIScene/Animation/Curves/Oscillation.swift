import Foundation
#if os(Android)
import Android
#endif

extension AnimationCurve {
    static func evaluateBounceOut(_ time: Float) -> Float {
        if time == 0 || time == 1 { return time }
        let scale: Float = 2.75
        let shifted: Float, floor: Float
        if time < 1 / scale { shifted = time; floor = 0 }
        else if time < 2 / scale { shifted = time - 1.5 / scale; floor = 0.75 }
        else if time < 2.5 / scale { shifted = time - 2.25 / scale; floor = 0.9375 }
        else { shifted = time - 2.625 / scale; floor = 0.984375 }
        return max(0, min(1, 7.5625 * shifted * shifted + floor))
    }

    static func evaluateElasticOut(_ time: Float) -> Float {
        if time == 0 || time == 1 { return time }
        let period: Float = 0.4
        return 1 + pow(2, -10 * time) * sin((time - period / 4) * (2 * .pi) / period)
    }
}
