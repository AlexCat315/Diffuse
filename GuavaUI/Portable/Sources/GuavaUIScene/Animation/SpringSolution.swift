import Foundation

/// The closed-form solution of a damped spring released from a given position
/// and velocity.
///
/// Time is measured from the release, so an animation that starts while the
/// property is already moving is *the same curve evaluated at a non-zero
/// start*, not a new curve from rest. That is the whole difference between an
/// interrupted animation continuing and an interrupted animation restarting —
/// a fixed-duration curve has no way to express it, because it only ever maps
/// elapsed time to progress.
///
/// Closed form rather than stepwise integration, for two reasons: the result
/// is independent of frame timing (a dropped frame does not change where the
/// spring ends up), and evaluating at absolute time makes resuming free.
public struct SpringSolution: Sendable, Equatable {
    /// Approximate period of one natural oscillation, in seconds.
    public let response: Float
    /// Classical damping ratio. Below 1 overshoots, 1 is critical, above 1 is
    /// overdamped.
    public let dampingFraction: Float

    private let omega0: Float
    private let zeta: Float
    private let omegaD: Float
    private let lambda1: Float
    private let lambda2: Float
    static func normalizedResponse(_ value: Double) -> Double {
        value.isFinite ? min(30, max(0.001, value)) : 0.4
    }
    static func normalizedDamping(_ value: Double) -> Double {
        value.isFinite ? min(20, max(0.01, value)) : 1
    }
    public init(response: Float, dampingFraction: Float) {
        let r = Float(Self.normalizedResponse(Double(response)))
        let z = Float(Self.normalizedDamping(Double(dampingFraction)))
        let w0 = (2 * Float.pi) / r

        var omegaD: Float = 0
        var lambda1: Float = 0
        var lambda2: Float = 0
        if z < 1 {
            omegaD = w0 * sqrt(max(0, 1 - z * z))
        } else if abs(z - 1) < 1e-4 {
            omegaD = w0
            lambda1 = -w0
            lambda2 = -w0
        } else {
            let root = sqrt(max(0, z * z - 1))
            lambda1 = -w0 * (z - root)
            lambda2 = -w0 * (z + root)
        }

        self.response = r; self.dampingFraction = z
        self.omega0 = w0; self.zeta = z; self.omegaD = omegaD
        self.lambda1 = lambda1; self.lambda2 = lambda2
    }

    /// Normalized progress in `[0, 1]` mapped to the seconds the physics runs
    /// on. Everything above and below works in seconds; this is the single
    /// conversion, so a curve sampled by elapsed time and one sampled by
    /// normalized time cannot drift apart.
    public func seconds(forNormalized t: Float) -> Float {
        t * response
    }

    /// Conservative settling bound in seconds, capped for nearly undamped input.
    public var settlingDuration: Double {
        let slowRate = zeta <= 1 ? zeta * omega0
            : omega0 / (zeta + sqrt(zeta * zeta - 1))
        return min(30, Double(12 / max(0.0001, slowRate)))
    }

    /// Progress at `t` seconds after release.
    ///
    /// May leave `[0, 1]`: an underdamped spring passing its target is the
    /// point, not a bug. Whether that is allowed to reach the animated value
    /// is the caller's decision — see `Animation.allowsOvershoot`.
    ///
    /// No endpoint normalization is applied: the equilibrium remains `target`
    /// for every initial velocity and every elapsed time.
    public func position(at t: Float, from start: Float, velocity startVelocity: Float,
                         to target: Float = 1) -> Float {
        if t <= 0 || t.isNaN { return start }
        if t == .infinity { return target }
        return target + rawPosition(t: t, start: start, velocity: startVelocity, target: target)
    }

    /// Rate of change of `position(at:)` with respect to time.
    ///
    /// This is the analytic derivative of position, measured in value units
    /// per real second.
    public func velocity(at t: Float, from start: Float, velocity startVelocity: Float,
                         to target: Float = 1) -> Float {
        if t <= 0 || t.isNaN { return startVelocity }
        if t == .infinity { return 0 }
        return rawVelocity(t: t, start: start, velocity: startVelocity, target: target)
    }

    // MARK: - Closed form

    private func rawPosition(t: Float, start: Float, velocity v: Float, target: Float) -> Float {
        let d = start - target
        if zeta < 1 {
            let envelope = exp(-zeta * omega0 * t)
            let a = d
            let b = (v + zeta * omega0 * d) / omegaD
            return envelope * (a * cos(omegaD * t) + b * sin(omegaD * t))
        }
        if abs(zeta - 1) < 1e-4 {
            let envelope = exp(-omega0 * t)
            let c = v + omega0 * d
            return envelope * (d + c * t)
        }
        let c1 = (v - lambda2 * d) / (lambda1 - lambda2)
        let c2 = (lambda1 * d - v) / (lambda1 - lambda2)
        return c1 * exp(lambda1 * t) + c2 * exp(lambda2 * t)
    }

    private func rawVelocity(t: Float, start: Float, velocity v: Float, target: Float) -> Float {
        let d = start - target
        if zeta < 1 {
            let envelope = exp(-zeta * omega0 * t)
            let a = d
            let b = (v + zeta * omega0 * d) / omegaD
            let cosT = cos(omegaD * t), sinT = sin(omegaD * t)
            return envelope * ((b * omegaD - zeta * omega0 * a) * cosT
                               - (a * omegaD + zeta * omega0 * b) * sinT)
        }
        if abs(zeta - 1) < 1e-4 {
            let envelope = exp(-omega0 * t)
            let c = v + omega0 * d
            return envelope * (v - omega0 * c * t)
        }
        let c1 = (v - lambda2 * d) / (lambda1 - lambda2)
        let c2 = (lambda1 * d - v) / (lambda1 - lambda2)
        return c1 * lambda1 * exp(lambda1 * t) + c2 * lambda2 * exp(lambda2 * t)
    }
}
