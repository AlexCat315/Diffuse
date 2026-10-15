import GuavaUICore
import Foundation

// MARK: - Type-erased controller

/// Common interface for the scheduler. Each controller owns a single
/// animated value and writes the interpolated result via its `apply`
/// closure on every tick.
///
/// The animator system is intentionally non-isolated: it is driven from a
/// single thread (the UI thread in production, the test thread in unit
/// tests). Marking it `@MainActor` would force every modifier `apply` site
/// to hop onto the main actor even in tests that operate purely on
/// synchronous state.
public protocol AnyAnimationController: AnyObject {
    /// `true` after timed playback or the physical settling tail has ended.
    /// Forever playback stays active until cancelled or explicitly finished.
    var isFinished: Bool { get }

    /// Advance the animation by `deltaTime` seconds and apply the resulting
    /// interpolated value via the controller's stored callback. Calling
    /// `tick` after `isFinished` becomes `true` is a no-op.
    func tick(deltaTime: Double)

    /// Snap the controller to its target value, mark it finished, and apply
    /// the final value once. The scheduler calls this when a controller is
    /// being replaced for the same property so the visible state matches the
    /// caller's intent.
    func finishImmediately()

    /// Stop the controller without applying any additional value.
    /// Used when a same-node/same-property animation is superseded by
    /// a newer target and should be discarded.
    func cancel()
}

// MARK: - Concrete controller

/// Drives one `Interpolatable` value from `from` to `to` over the lifetime
/// of an `Animation`. The controller is value-agnostic — it does not know
/// which property it writes; the caller's `apply` closure handles that
/// (typically `{ value in node.backgroundColor = value }`).
public final class AnimationController<Value: Interpolatable>: AnyAnimationController {
    public let from: Value
    public let to: Value
    public let animation: Animation
    public let apply: (Value) -> Void
    public private(set) var elapsed: Double = 0
    public private(set) var isFinished = false
    public private(set) var progressVelocity: Float = 0
    public var onFinish: (() -> Void)?
    var onLogicalFinish: (() -> Void)?
    var onCancel: (() -> Void)?
    private var logicalFinished = false
    private var motion: MotionVector<Value>?
    private let spring: SpringSolution?
    private let releaseVelocity: Float

    public init(from: Value, to: Value, animation: Animation,
                initialVelocity: Float = 0, apply: @escaping (Value) -> Void) {
        self.from = from; self.to = to; self.animation = animation; self.apply = apply
        let velocity = initialVelocity == 0 ? animation.initialVelocity : initialVelocity
        releaseVelocity = velocity.isFinite ? velocity : 0
        if case let .spring(response, damping) = animation.curve {
            spring = SpringSolution(response: response, dampingFraction: damping)
        } else { spring = nil }
        if animation.duration == 0, animation.delay == 0 {
            apply(to); isFinished = true; logicalFinished = true
        }
    }

    var isLogicallyFinished: Bool { logicalFinished }

    /// Capture the outgoing value velocity, including prior interruptions. A
    /// bounded animation starts from rest so its value stays inside its bounds.
    func inheritMotion(from previous: AnimationController<Value>) {
        guard spring != nil, animation.allowsOvershoot, releaseVelocity == 0, !previous.isFinished else { return }
        let active = max(0, previous.elapsed - previous.animation.delay)
        let lower = max(0, active - 0.0001), upper = active + 0.0001
        motion = MotionVector(from: previous.value(at: lower), to: previous.value(at: upper),
                              rate: Float(1 / (upper - lower)))
    }

    private func springProgress(at active: Double) -> Float {
        guard let spring else { return 0 }
        return spring.position(at: Float(active), from: 0, velocity: releaseVelocity)
    }

    private func value(at active: Double) -> Value {
        if let spring, animation.repetition == .once {
            let progress = springProgress(at: active)
            let bounded = animation.allowsOvershoot ? progress : max(0, min(1, progress))
            let base = Value.interpolate(from, to, t: bounded)
            if let motion, animation.allowsOvershoot {
                let impulse = spring.position(at: Float(active), from: 0, velocity: 1, to: 0)
                return motion.adding(to: base, seconds: impulse)
            }
            return base
        }
        let time = animation.playback(at: active + animation.delay).time
        let progress = animation.curve.evaluate(time)
        return Value.interpolate(from, to, t: animation.allowsOvershoot ? progress : max(0, min(1, progress)))
    }

    public func tick(deltaTime: Double) {
        guard !isFinished, deltaTime.isFinite, deltaTime >= 0 else { return }
        elapsed = min(Double.greatestFiniteMagnitude, elapsed + deltaTime)
        let active = elapsed - animation.delay
        guard active > 0 else { apply(from); return }
        if let spring, animation.repetition == .once, animation.duration > 0 {
            let t = Float(active)
            let progress = springProgress(at: active)
            progressVelocity = spring.velocity(at: t, from: 0, velocity: releaseVelocity)
            if active >= animation.duration { finishLogical() }
            // An envelope bound prevents a zero crossing from falsely looking
            // settled. The cap also bounds pathological near-zero damping.
            let restTime = max(animation.duration, spring.settlingDuration)
            if active >= restTime {
                apply(to); finish(); return
            }
            if !progress.isFinite { apply(to); finish(); return }
            apply(value(at: active))
        } else {
            let sample = animation.playback(at: elapsed)
            if sample.finished {
                apply(sample.time == 0 ? from : to); finish(); return
            }
            apply(value(at: active))
        }
    }

    private func finishLogical() {
        guard !logicalFinished else { return }
        logicalFinished = true; onLogicalFinish?()
    }
    private func finish() {
        finishLogical(); isFinished = true; progressVelocity = 0; onFinish?()
    }
    public func finishImmediately() {
        guard !isFinished else { return }
        apply(to); finish()
    }
    public func cancel() {
        guard !isFinished else { return }
        isFinished = true; progressVelocity = 0; onCancel?()
    }
}
