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
    /// Scales position *and* velocity so a spring released from rest lands
    /// exactly on its target at `t == response`. Without it the closed form
    /// arrives close to, but not exactly at, the target, and the final frame
    /// would show the difference.
    private let normalization: Float

    private init(omega0: Float, zeta: Float, omegaD: Float,
                 lambda1: Float, lambda2: Float, normalization: Float) {
        self.omega0 = omega0
        self.zeta = zeta
        self.omegaD = omegaD
        self.lambda1 = lambda1
        self.lambda2 = lambda2
        self.normalization = normalization
        self.response = 2 * Float.pi / omega0
        self.dampingFraction = zeta
    }

    public init(response: Float, dampingFraction: Float) {
        let r = max(0.0001, response)
        let z = max(0.0001, dampingFraction)
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

        // Probe unnormalized to find where a spring released from rest lands after
        // one response period, then scale by the reciprocal so it lands exactly
        // on the target. Position and velocity share the scale, so the rate
        // handed to a successor stays consistent with the path that produced
        // it.
        let probe = SpringSolution(omega0: w0, zeta: z, omegaD: omegaD,
                                   lambda1: lambda1, lambda2: lambda2, normalization: 1)
        let atOne = 1 + probe.rawPosition(t: r, start: 0, velocity: 0, target: 1)
        let scale = abs(atOne) > 1e-5 ? 1 / atOne : 1
        self.init(omega0: w0, zeta: z, omegaD: omegaD,
                  lambda1: lambda1, lambda2: lambda2, normalization: scale)
    }

    /// Normalized progress in `[0, 1]` mapped to the seconds the physics runs
    /// on. Everything above and below works in seconds; this is the single
    /// conversion, so a curve sampled by elapsed time and one sampled by
    /// normalized time cannot drift apart.
    public func seconds(forNormalized t: Float) -> Float {
        t * response
    }

    /// Progress at `t` seconds after release.
    ///
    /// May leave `[0, 1]`: an underdamped spring passing its target is the
    /// point, not a bug. Whether that is allowed to reach the animated value
    /// is the caller's decision — see `Animation.allowsOvershoot`.
    ///
    /// The normalization that anchors a released-from-rest spring to its target
    /// at `t == response` applies *only* to that case. A spring that inherits
    /// velocity is already in motion, and forcing it to land exactly at the
    /// same instant would distort the very motion it was handed.
    public func position(at t: Float, from start: Float, velocity startVelocity: Float,
                         to target: Float = 1) -> Float {
        // The target sits *inside* the normalization: the scale is the
        // reciprocal of where an unnormalized spring lands after one response
        // period, and folding the target in afterwards would leave position(0)
        // off by whatever the scale is.
        let raw = target + rawPosition(t: t, start: start, velocity: startVelocity, target: target)
        return startVelocity == 0 ? raw * normalization : raw
    }

    /// Rate of change of `position(at:)` with respect to time.
    ///
    /// Carried so an animation that supersedes this one can hand its motion
    /// over instead of dropping it. Uses the same normalization as
    /// `position(at:)`, so the rate matches the path that produced it.
    public func velocity(at t: Float, from start: Float, velocity startVelocity: Float,
                         to target: Float = 1) -> Float {
        let rate = rawVelocity(t: t, start: start, velocity: startVelocity, target: target)
        return rate * (startVelocity == 0 ? normalization : 1)
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