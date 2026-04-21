import Foundation

// MARK: - AnimationCurve

/// Easing curve mapping normalized time `t ∈ [0, 1]` to normalized progress
/// `p ∈ [0, 1]`. Pure value type with no theme dependency — Phase 7.5's
/// `Easing` struct lives in the Compose layer and feeds into `Animation` via
/// `.cubicBezier(...)` here when needed.
public enum AnimationCurve: Sendable, Equatable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    /// Cubic Bezier with control points `(c1x, c1y)` and `(c2x, c2y)`.
    /// Anchors `(0, 0)` and `(1, 1)` are implied.
    case cubicBezier(Float, Float, Float, Float)

    /// Map normalized time to normalized progress. Inputs outside `[0, 1]`
    /// are clamped before evaluation.
    public func evaluate(_ t: Float) -> Float {
        let x = max(0, min(1, t))
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
        case let .cubicBezier(c1x, c1y, c2x, c2y):
            return Self.evaluateCubicBezier(x: x, c1x: c1x, c1y: c1y, c2x: c2x, c2y: c2y)
        }
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

    public init(duration: Double,
                curve: AnimationCurve = .easeInOut,
                delay: Double = 0) {
        self.duration = duration
        self.curve = curve
        self.delay = delay
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

    /// Convenience for setting a custom duration while keeping `easeInOut`.
    static func easeInOut(duration: Double) -> Animation {
        Animation(duration: duration, curve: .easeInOut)
    }
}
