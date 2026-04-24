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
    public private(set) var isFinished: Bool = false

    public init(from: Value,
                to: Value,
                animation: Animation,
                apply: @escaping (Value) -> Void) {
        self.from = from
        self.to = to
        self.animation = animation
        self.apply = apply

        // Zero or negative duration ⇒ snap immediately. Still apply once so
        // the target value is visible on this frame.
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

        if active >= animation.duration {
            apply(to)
            isFinished = true
            return
        }

        let t = Float(active / animation.duration)
        let p = animation.curve.evaluate(t)
        apply(Value.interpolate(from, to, t: p))
    }

    public func finishImmediately() {
        guard !isFinished else { return }
        apply(to)
        isFinished = true
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

    public init() {}

    /// Number of controllers currently being driven. Useful for tests that
    /// want to assert lifecycle (registration, eviction).
    public var activeCount: Int { active.count }

    public var hasActiveAnimations: Bool { !active.isEmpty }

    /// Register a controller for per-frame ticking. The scheduler retains a
    /// strong reference until the controller becomes finished, after which
    /// it is dropped on the next `tick`.
    public func register(_ controller: AnyAnimationController) {
        if active.contains(where: \.isFinished) {
            active.removeAll(where: \.isFinished)
        }
        active.append(controller)
    }

    /// Advance every registered controller by `deltaTime` seconds, then
    /// remove any that finished during the sweep.
    public func tick(deltaTime: Double) {
        for c in active { c.tick(deltaTime: deltaTime) }
        if active.contains(where: \.isFinished) {
            active.removeAll(where: \.isFinished)
        }
    }

    /// Drop every active controller without applying any final value.
    /// Intended for test isolation; production code should let controllers
    /// run to completion or replace them via `finishImmediately()`.
    public func reset() {
        active.removeAll()
    }
}
