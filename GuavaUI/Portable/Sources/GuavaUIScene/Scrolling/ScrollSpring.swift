import GuavaUICore

/// Damped harmonic oscillator that pulls one scroll axis back inside its
/// bounds after release.
///
/// Integrated rather than solved analytically because the spring is
/// *interrupted*: every new input delta restarts it from wherever the content
/// currently sits, carrying whatever velocity it still had. A closed-form
/// solution would need the elapsed time rewritten into every restart; keeping
/// position/velocity as state makes a restart a plain assignment.
///
/// Semi-implicit Euler (velocity integrated first, then used to advance the
/// value) is energy-stable for this system, unlike explicit Euler which gains
/// energy and visibly explodes when the damping ratio drops below 1.
public struct ScrollSpring: Sendable, Equatable {
    public var value: Float
    public var velocity: Float
    public var target: Float
    public var settings: ScrollSettleSettings

    public init(value: Float,
                velocity: Float = 0,
                target: Float,
                settings: ScrollSettleSettings = .init()) {
        self.value = value
        self.velocity = velocity
        self.target = target
        self.settings = settings
    }

    /// `true` once the spring is close enough to rest that stepping further
    /// would not be visible.
    public var isAtRest: Bool {
        abs(value - target) <= settings.positionTolerance
            && abs(velocity) <= settings.velocityTolerance
    }

    /// Advance by `deltaTime` seconds. Large steps are split so a long frame
    /// (window drag, shader compile) cannot overshoot the solution.
    public mutating func advance(deltaTime: Float) {
        guard deltaTime > 0, !isAtRest else {
            snapToTarget()
            return
        }

        let omega = (2 * Float.pi) / max(0.0001, settings.response)
        let stiffness = omega * omega
        let damping = 2 * max(0.0001, settings.dampingFraction) * omega

        var remaining = deltaTime
        while remaining > 0 {
            let step = min(remaining, settings.maximumTimeStep)
            remaining -= step
            velocity += (-stiffness * (value - target) - damping * velocity) * step
            value += velocity * step
        }

        if isAtRest { snapToTarget() }
    }

    public mutating func snapToTarget() {
        value = target
        velocity = 0
    }
}
