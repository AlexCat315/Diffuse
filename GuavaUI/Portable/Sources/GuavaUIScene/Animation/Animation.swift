import GuavaUICore
#if os(Android)
import Android
#endif
import Foundation

// MARK: - AnimationCurve

/// Easing curve mapping normalized time `t ∈ [0, 1]` to progress. Overshooting
/// curves can return progress outside `[0, 1]`. Pure value type with no theme dependency — Phase 7.5's
/// `Easing` struct lives in the Compose layer and feeds into `Animation` via
/// `.cubicBezier(...)` here when needed.
public enum AnimationCurve: Sendable, Equatable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    /// Equal intervals with a jump at the start or end of each interval.
    /// Nonpositive counts resolve to one interval.
    case steps(Int, position: AnimationStepPosition = .end)
    /// Linear interpolation through authored time/progress points.
    case piecewiseLinear(LinearTimingCurve)
    /// Four diminishing parabolic bounces, bounded to `[0, 1]`.
    case bounceOut
    /// Decaying oscillation with overshoot and a normalized period of 0.4.
    case elasticOut
    /// Damped spring curve using a response period and damping fraction.
    ///
    /// `response` is the approximate period in seconds for a single natural
    /// oscillation. `dampingFraction` maps to classical damping ratio:
    /// - `1.0`  => critical damping (no overshoot)
    /// - `< 1`  => underdamped (can overshoot)
    /// - `> 1`  => overdamped (slower settle)
    ///
    /// The runtime clamps the evaluated progress into `[0, 1]` to keep
    /// interpolation stable across all value types.
    case spring(response: Float, dampingFraction: Float)
    /// Cubic Bezier with control points `(c1x, c1y)` and `(c2x, c2y)`.
    /// Anchors `(0, 0)` and `(1, 1)` are implied.
    case cubicBezier(Float, Float, Float, Float)

    /// Map normalized time to progress, preserving overshoot. Inputs outside
    /// `[0, 1]` are clamped; NaN is treated as zero.
    public func evaluate(_ t: Float) -> Float {
        let x = t.isNaN ? 0 : max(0, min(1, t))
        switch self {
        case .linear:
            return x
        case .easeIn:
            // y = x²
            return x * x
        case .easeOut:
            // y = 1 - (1 - x)²
            let inv = 1 - x
            return 1 - inv * inv
        case .easeInOut:
            // Symmetric ease, smoothstep-like quadratic blend.
            if x < 0.5 {
                return 2 * x * x
            } else {
                let inv = 1 - x
                return 1 - 2 * inv * inv
            }
        case let .steps(count, position):
            return Self.evaluateSteps(x: x, count: count, position: position)
        case let .piecewiseLinear(curve):
            return curve.evaluate(x)
        case .bounceOut:
            return Self.evaluateBounceOut(x)
        case .elasticOut:
            return Self.evaluateElasticOut(x)
        case let .spring(response, dampingFraction):
            return Self.evaluateSpring(
                x: x,
                response: response,
                dampingFraction: dampingFraction
            )
        case let .cubicBezier(c1x, c1y, c2x, c2y):
            return Self.evaluateCubicBezier(x: x, c1x: c1x, c1y: c1y, c2x: c2x, c2y: c2y)
        }
    }

    /// A damped spring released from rest, normalized so `f(0)=0` and `f(1)=1`.
    ///
    /// Not clamped: an underdamped spring passing its target is the point, and
    /// `SpringSolution` carries the initial velocity that a curve cannot
    /// express. Whether progress may leave `[0, 1]` on the way to an animated
    /// value is `Animation.allowsOvershoot`'s decision, not the curve's.
    private static func evaluateSpring(x: Float,
                                       response: Float,
                                       dampingFraction: Float) -> Float {
        let spring = SpringSolution(response: response, dampingFraction: dampingFraction)
        return spring.position(at: spring.seconds(forNormalized: x), from: 0, velocity: 0)
    }

    /// Solve the cubic Bezier `y(x)` defined by the four control points
    /// `(0, 0)`, `(c1x, c1y)`, `(c2x, c2y)`, `(1, 1)` for the given `x`.
    /// Uses Newton-Raphson on the parametric `Bx(t)` to recover `t`, then
    /// evaluates `By(t)`. Falls back to bisection if Newton diverges.
    private static func evaluateCubicBezier(x: Float,
                                            c1x: Float, c1y: Float,
                                            c2x: Float, c2y: Float) -> Float {
        // Polynomial coefficients for Bx(t) = ax·t³ + bx·t² + cx·t.
        let cx = 3 * c1x
        let bx = 3 * (c2x - c1x) - cx
        let ax = 1 - cx - bx

        let cy = 3 * c1y
        let by = 3 * (c2y - c1y) - cy
        let ay = 1 - cy - by

        @inline(__always) func sampleX(_ t: Float) -> Float {
            ((ax * t + bx) * t + cx) * t
        }
        @inline(__always) func sampleY(_ t: Float) -> Float {
            ((ay * t + by) * t + cy) * t
        }
        @inline(__always) func sampleDX(_ t: Float) -> Float {
            (3 * ax * t + 2 * bx) * t + cx
        }

        // Newton-Raphson — usually converges in 4 iterations for well-behaved
        // curves.
        var t = x
        for _ in 0..<8 {
            let fx = sampleX(t) - x
            if abs(fx) < 1e-5 { return sampleY(t) }
            let dx = sampleDX(t)
            if abs(dx) < 1e-6 { break }
            t -= fx / dx
        }

        // Bisection fallback.
        var lo: Float = 0, hi: Float = 1
        t = x
        for _ in 0..<32 {
            let fx = sampleX(t)
            if abs(fx - x) < 1e-5 { return sampleY(t) }
            if fx < x { lo = t } else { hi = t }
            t = (lo + hi) * 0.5
        }
        return sampleY(t)
    }
}

// MARK: - Animation

/// Description of how a value should transition to its target. Pure value
/// type; the runtime scheduler consumes this when building per-property
/// `AnimationController` instances.
public struct Animation: Sendable, Equatable {
    /// Total time, in seconds, for the value to travel from `from` to `to`.
    /// Must be > 0 to take effect; non-positive durations behave as if no
    /// animation was requested.
    public let duration: Double

    /// Easing curve applied to normalized elapsed time.
    public let curve: AnimationCurve

    /// Delay before interpolation starts, in seconds. The controller still
    /// holds the `from` value during this window.
    public let delay: Double

    /// Whether progress is allowed to leave `[0, 1]` on its way to the target.
    ///
    /// A spring under 1.0 damping passes its target before it settles, and
    /// that overshoot is most of what makes it feel physical. It is also only
    /// valid for values that can express it: an offset or a scale can sit past
    /// where it is going, but an alpha, a colour channel or a corner radius
    /// cannot, and letting one go out of range is a visual bug rather than an
    /// effect.
    ///
    /// Default `false`, so existing animations — including every semantic
    /// motion token, several of which use springs — are unaffected. Opt in per
    /// animation, on properties known to tolerate it.
    public let allowsOvershoot: Bool

    public init(duration: Double,
                curve: AnimationCurve = .easeInOut,
                delay: Double = 0,
                allowsOvershoot: Bool = false) {
        self.duration = duration
        self.curve = curve
        self.delay = delay
        self.allowsOvershoot = allowsOvershoot
    }
}

public extension Animation {
    /// `easeInOut` over 0.25 s.
    static let `default` = Animation(duration: 0.25, curve: .easeInOut)

    /// Linear interpolation over 0.25 s.
    static let linear = Animation(duration: 0.25, curve: .linear)

    /// `easeIn` over 0.25 s.
    static let easeIn = Animation(duration: 0.25, curve: .easeIn)

    /// `easeOut` over 0.25 s.
    static let easeOut = Animation(duration: 0.25, curve: .easeOut)

    /// `easeInOut` over 0.25 s.
    static let easeInOut = Animation(duration: 0.25, curve: .easeInOut)

    /// Spring tuned for snappy control interactions.
    static let snappy = Animation.spring(response: 0.30, dampingFraction: 0.90)

    /// Spring tuned for bouncy decorative motion.
    static let bouncy = Animation.spring(response: 0.45, dampingFraction: 0.65)

    /// Convenience for setting a custom duration while keeping `easeInOut`.
    static func easeInOut(duration: Double) -> Animation {
        Animation(duration: duration, curve: .easeInOut)
    }

    /// Spring animation convenience. Uses spring dynamics as the easing
    /// curve while setting animation duration to `response`.
    static func spring(response: Double = 0.40,
                       dampingFraction: Double = 0.82,
                       delay: Double = 0) -> Animation {
        let r = max(0.0001, response)
        let d = max(0.0001, dampingFraction)
        return Animation(
            duration: r,
            curve: .spring(response: Float(r), dampingFraction: Float(d)),
            delay: delay
        )
    }
}
