import SIMDCompat

public enum Easing: Sendable, Equatable {
    case linear
    case easeInQuad, easeOutQuad, easeInOutQuad
    case easeInCubic, easeOutCubic, easeInOutCubic
    case easeInQuart, easeOutQuart, easeInOutQuart
    case easeInQuint, easeOutQuint, easeInOutQuint
    case easeInSine, easeOutSine, easeInOutSine
    case easeInExpo, easeOutExpo, easeInOutExpo
    case easeInCirc, easeOutCirc, easeInOutCirc
    case easeInElastic, easeOutElastic, easeInOutElastic
    case easeInBack, easeOutBack, easeInOutBack
    case easeInBounce, easeOutBounce, easeInOutBounce

    /// Evaluates the easing function at `t` in [0, 1]. Clamps t to [0, 1].
    public func evaluate(_ t: Float) -> Float {
        let t = simd_clamp(t, 0, 1)
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        switch self {
        case .linear: return t

        case .easeInQuad:  return t * t
        case .easeOutQuad: return t * (2 - t)
        case .easeInOutQuad: return t < 0.5 ? 2*t*t : -1 + (4 - 2*t)*t

        case .easeInCubic:  return t * t * t
        case .easeOutCubic: let t1 = t - 1; return t1*t1*t1 + 1
        case .easeInOutCubic: return t < 0.5 ? 4*t*t*t : (t-1)*(2*t-2)*(2*t-2) + 1

        case .easeInQuart:  return t * t * t * t
        case .easeOutQuart: let t1 = t - 1; return 1 - t1*t1*t1*t1
        case .easeInOutQuart: return t < 0.5 ? 8*t*t*t*t : 1 - pow(-2*t + 2, 4)/2

        case .easeInQuint:  return t * t * t * t * t
        case .easeOutQuint: let t1 = t - 1; return 1 + t1*t1*t1*t1*t1
        case .easeInOutQuint: return t < 0.5 ? 16*t*t*t*t*t : 1 - pow(-2*t + 2, 5)/2

        case .easeInSine:   return 1 - cos(t * .pi / 2)
        case .easeOutSine:  return sin(t * .pi / 2)
        case .easeInOutSine: return -(cos(.pi * t) - 1) / 2

        case .easeInExpo:   return t == 0 ? 0 : pow(2, 10*t - 10)
        case .easeOutExpo:  return t == 1 ? 1 : 1 - pow(2, -10*t)
        case .easeInOutExpo: return t == 0 ? 0 : t == 1 ? 1 : t < 0.5
            ? pow(2, 20*t - 10) / 2
            : (2 - pow(2, -20*t + 10)) / 2

        case .easeInCirc:   return 1 - sqrt(1 - t*t)
        case .easeOutCirc:  return sqrt(1 - (t-1)*(t-1))
        case .easeInOutCirc: return t < 0.5
            ? (1 - sqrt(1 - 4*t*t)) / 2
            : (sqrt(1 - pow(-2*t + 2, 2)) + 1) / 2

        case .easeInElastic:  return elasticIn(t)
        case .easeOutElastic: return elasticOut(t)
        case .easeInOutElastic: return elasticInOut(t)

        case .easeInBack:  return c3*t*t*t - c1*t*t
        case .easeOutBack: return 1 + c3*pow(t-1, 3) + c1*pow(t-1, 2)
        case .easeInOutBack: return t < 0.5
            ? (pow(2*t, 2) * ((c2+1)*2*t - c2)) / 2
            : (pow(2*t - 2, 2) * ((c2+1)*(t*2-2) + c2) + 2) / 2

        case .easeInBounce:  return 1 - bounceOut(1 - t)
        case .easeOutBounce: return bounceOut(t)
        case .easeInOutBounce: return t < 0.5
            ? (1 - bounceOut(1 - 2*t)) / 2
            : (1 + bounceOut(2*t - 1)) / 2
        }
    }

    /// Interpolates between `from` and `to` using the easing function.
    public func interpolate(from: Float, to: Float, t: Float) -> Float {
        from + (to - from) * evaluate(t)
    }

    /// Interpolates `SIMD3<Float>` using the easing function.
    public func interpolate(from: SIMD3<Float>, to: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        from + (to - from) * evaluate(t)
    }
}

private let c1: Float = 1.70158
private let c2: Float = c1 * 1.525
private let c3: Float = c1 + 1
private let c4: Float = (2 * .pi) / 3
private let c5: Float = (2 * .pi) / 4.5

private func elasticIn(_ t: Float) -> Float {
    t == 0 ? 0 : t == 1 ? 1 : -pow(2, 10*t - 10) * sin((t*10 - 10.75) * c4)
}

private func elasticOut(_ t: Float) -> Float {
    t == 0 ? 0 : t == 1 ? 1 : pow(2, -10*t) * sin((t*10 - 0.75) * c4) + 1
}

private func elasticInOut(_ t: Float) -> Float {
    if t == 0 { return 0 }; if t == 1 { return 1 }
    return t < 0.5
        ? -(pow(2, 20*t - 10) * sin((20*t - 11.125) * c5)) / 2
        : (pow(2, -20*t + 10) * sin((20*t - 11.125) * c5)) / 2 + 1
}

private func bounceOut(_ t: Float) -> Float {
    let n1: Float = 7.5625, d1: Float = 2.75
    var t = t
    if t < 1/d1 { return n1*t*t }
    else if t < 2/d1 { t -= 1.5/d1; return n1*t*t + 0.75 }
    else if t < 2.5/d1 { t -= 2.25/d1; return n1*t*t + 0.9375 }
    else { t -= 2.625/d1; return n1*t*t + 0.984375 }
}
