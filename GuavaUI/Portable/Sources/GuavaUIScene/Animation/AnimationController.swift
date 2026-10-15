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
    /// `true` once the animation has reached `delay + duration`. Finished
    /// controllers are removed from the scheduler on the next sweep.
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

/// A controller that drives an interpolated value from a start to a target.
///
/// Separate from `AnyAnimationController` because the protocol is also
/// implemented by clocks and timers that keep the scheduler producing frames
/// without interpolating anything. Those have no progress and so cannot hand
/// motion to whatever supersedes them.
public protocol ProgressReporting: AnyAnimationController {
    /// Rate of change of progress per second as of the last tick.
    var progressVelocity: Float { get }
}

// MARK: - Concrete controller

/// Drives one `Interpolatable` value from `from` to `to` over the lifetime
/// of an `Animation`. The controller is value-agnostic — it does not know
/// which property it writes; the caller's `apply` closure handles that
/// (typically `{ value in node.backgroundColor = value }`).
public final class AnimationController<Value: Interpolatable>: ProgressReporting {

    public let from: Value
    public let to: Value
    public let animation: Animation
    public let apply: (Value) -> Void

    public private(set) var elapsed: Double = 0
    public private(set) var isFinished: Bool = false

    /// Invoked once when the animation reaches its target on its own — from
    /// `tick` running out of time, or from `finishImmediately`. Deliberately
    /// *not* invoked by `cancel`: a superseded animation was abandoned, not
    /// completed, and a `withAnimation` completion must not fire for one.
    ///
    /// Only this class carries it. The protocol is also implemented by clocks
    /// and timers that drive the scheduler without interpolating a value, and
    /// none of those can complete an animated scope.
    public var onFinish: (() -> Void)?

    /// `nil` for every curve except a spring. A spring is evaluated from the
    /// value it inherits rather than sampled from elapsed time, which is what
    /// lets an interrupted animation keep its velocity.
    private var spring: SpringSolution?
    private var initialVelocity: Float = 0
    private var lastProgress: Float = 0

    /// Rate of change of progress per second as of the last tick.
    ///
    /// Hand to the animation that supersedes this one so it continues the
    /// motion rather than restarting it. Zero until the first tick, and zero
    /// for anything that is not a spring.
    public private(set) var progressVelocity: Float = 0

    /// Fire once, and only for a real completion. `cancel` deliberately does
    /// not come through here.
    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        onFinish?()
    }

    /// Progress at `active` seconds after the animation started, clamped to
    /// `[0, 1]` unless the animation opted into overshoot.
    ///
    /// A spring's time is already in seconds — its `response` *is* its clock —
    /// so it is solved at `active` directly. Every other curve maps
    /// normalized `[0, 1]` time, so it sees `active / duration`.
    private func progress(at active: Double) -> Float {
        let raw: Float
        if let spring {
            // Normalized elapsed time, converted to the seconds the spring's
            // physics runs on — the same conversion `AnimationCurve.spring`
            // makes, so the two paths agree at every instant.
            let t = spring.seconds(forNormalized: Float(active / animation.duration))
            raw = spring.position(at: t, from: 0, velocity: initialVelocity)
        } else {
            raw = animation.curve.evaluate(Float(active / animation.duration))
        }
        return animation.allowsOvershoot ? raw : max(0, min(1, raw))
    }

    public init(from: Value,
                to: Value,
                animation: Animation,
                initialVelocity: Float = 0,
                apply: @escaping (Value) -> Void) {
        self.from = from
        self.to = to
        self.animation = animation
        self.apply = apply
        if case let .spring(response, damping) = animation.curve {
            spring = SpringSolution(response: response, dampingFraction: damping)
            self.initialVelocity = initialVelocity
        }

        // Zero or negative duration ⇒ snap immediately. Still apply once so
        // the target value is visible on this frame. `onFinish` is not called
        // from here: a caller that attaches after construction sees
        // `isFinished` and settles the group itself.
        if animation.duration <= 0 && animation.delay <= 0 {
            apply(to)
            isFinished = true
        }
    }

    public func tick(deltaTime: Double) {
        guard !isFinished else { return }

        elapsed += deltaTime
        let active = elapsed - animation.delay

        if active <= 0 {
            // Still in the delay window — keep the from value pinned.
            apply(from)
            return
        }

        let previous = lastProgress
        lastProgress = progress(at: active)
        if deltaTime > 0 {
            progressVelocity = (lastProgress - previous) / Float(deltaTime)
        }

        if active >= animation.duration {
            apply(to)
            finish()
            return
        }

        apply(Value.interpolate(from, to, t: lastProgress))
    }

    public func finishImmediately() {
        guard !isFinished else { return }
        apply(to)
        finish()
    }

    public func cancel() {
        isFinished = true
    }
}

// MARK: - Scheduler

/// Per-thread registry of in-flight animation controllers. The platform
/// shell calls `tick(deltaTime:)` once per frame on the UI thread. Finished
/// controllers drop out automatically on the next tick.
///
/// Like the controllers themselves, the scheduler is non-isolated because
/// the UI runtime is single-threaded by construction. Concurrent access
/// from multiple threads is not supported.
///
/// **Test isolation**: The scheduler used by `Node.animatableSet` is
/// resolved through the `current` task-local. Tests can install a fresh
/// scheduler for the scope of a closure with
/// `AnimatorScheduler.$current.withValue(AnimatorScheduler()) { ... }`,
/// avoiding cross-test interference on the shared global.
public final class AnimatorScheduler: @unchecked Sendable {

    /// Default scheduler used by the Compose layer. Tests may instantiate a
    /// fresh `AnimatorScheduler()` and drive it manually.
    public static let shared = AnimatorScheduler()

    /// The scheduler that `Node.animatableSet` (and friends) registers
    /// controllers with. Defaults to `.shared`. Override via
    /// `$current.withValue(_:)` to scope a different scheduler to a task.
    @TaskLocal public static var current: AnimatorScheduler = AnimatorScheduler.shared

    private var active: [AnyAnimationController] = []
    private var completions: [AnimationCompletionGroup] = []

    public init() {}

    /// Number of controllers currently being driven. Useful for tests that
    /// want to assert lifecycle (registration, eviction).
    public var activeCount: Int { active.count }

    public var hasActiveAnimations: Bool { !active.isEmpty }

    /// Register a controller for per-frame ticking. The scheduler retains a
    /// strong reference until the controller becomes finished, after which
    /// it is dropped on the next `tick`.
    public func register(_ controller: AnyAnimationController) {
        active.removeAll { $0.isFinished || $0 === controller }
        active.append(controller)
    }

    /// Release a repeating controller immediately when its view is paused or
    /// removed. Registering it again later resumes with one scheduler entry.
    public func unregister(_ controller: AnyAnimationController) {
        active.removeAll { $0 === controller }
    }

    /// Watch a `withAnimation` completion group. The group is asked to settle at
    /// the end of every sweep, which is what lets a callback fire on the frame
    /// its last controller finishes — and also fire (correctly) on the first
    /// sweep when the mutation turned out to animate nothing.
    public func track(_ group: AnimationCompletionGroup) {
        completions.append(group)
    }

    /// Advance every registered controller by `deltaTime` seconds, then
    /// remove any that finished during the sweep.
    public func tick(deltaTime: Double) {
        for c in active { c.tick(deltaTime: deltaTime) }
        if active.contains(where: \.isFinished) {
            active.removeAll(where: \.isFinished)
        }
        if !completions.isEmpty {
            for group in completions { group.settleIfIdle() }
            completions.removeAll(where: \.hasSettled)
        }
    }

    /// Drop every active controller without applying any final value.
    /// Intended for test isolation; production code should let controllers
    /// run to completion or replace them via `finishImmediately()`.
    public func reset() {
        active.removeAll()
        completions.removeAll()
    }
}
