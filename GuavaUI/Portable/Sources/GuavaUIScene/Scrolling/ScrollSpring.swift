import Foundation

/// Analytic damped spring in visible logical coordinates. Solving the motion
/// directly keeps interruptions and uneven frames independent of substeps.
public struct ScrollSpring: Sendable, Equatable {
    public var value: Float
    public var velocity: Float
    public var target: Float
    public var settings: ScrollSettleSettings

    public init(value: Float, velocity: Float = 0, target: Float,
                settings: ScrollSettleSettings = .init()) {
        self.value = value
        self.velocity = velocity
        self.target = target
        self.settings = settings
    }

    public var isAtRest: Bool {
        abs(value - target) <= max(0, settings.positionTolerance)
            && abs(velocity) <= max(0, settings.velocityTolerance)
    }

    public mutating func advance(deltaTime: Float) {
        guard deltaTime.isFinite, deltaTime > 0 else { return }
        if isAtRest { snapToTarget(); return }
        let omega = 2 * Double.pi / Double(max(0.0001, settings.response))
        let ratio = Double(max(0, settings.dampingFraction))
        let time = Double(deltaTime)
        let displacement = Double(value - target)
        let speed = Double(velocity)
        let next: Double
        let nextSpeed: Double
        if abs(ratio - 1) < 0.00001 {
            let b = speed + omega * displacement
            let decay = exp(-omega * time)
            next = (displacement + b * time) * decay
            nextSpeed = (speed - omega * b * time) * decay
        } else if ratio < 1 {
            let damped = omega * sqrt(1 - ratio * ratio)
            let decay = exp(-ratio * omega * time)
            let b = (speed + ratio * omega * displacement) / damped
            let phase = damped * time
            next = decay * (displacement * cos(phase) + b * sin(phase))
            nextSpeed = -ratio * omega * next
                + decay * damped * (-displacement * sin(phase) + b * cos(phase))
        } else {
            let root = sqrt(ratio * ratio - 1)
            let slow = -omega / (ratio + root)
            let fast = -omega * (ratio + root)
            let a = (speed - fast * displacement) / (slow - fast)
            let b = displacement - a
            next = a * exp(slow * time) + b * exp(fast * time)
            nextSpeed = slow * a * exp(slow * time) + fast * b * exp(fast * time)
        }
        value = target + Float(next)
        velocity = Float(nextSpeed)
        if isAtRest { snapToTarget() }
    }

    public mutating func snapToTarget() { value = target; velocity = 0 }
}
