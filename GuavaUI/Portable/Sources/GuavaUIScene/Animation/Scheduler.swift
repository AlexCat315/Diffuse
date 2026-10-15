import Foundation

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
        guard !controller.isFinished else { return }
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
        group.onSettlement = { [weak self, weak group] in
            self?.completions.removeAll { $0 === group }
        }
        completions.append(group)
    }

    /// Advance every registered controller by `deltaTime` seconds, then
    /// remove any that finished during the sweep.
    public func tick(deltaTime: Double) {
        guard deltaTime.isFinite, deltaTime >= 0 else { return }
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
        for controller in active { controller.cancel() }
        active.removeAll()
        completions.removeAll()
    }
}
