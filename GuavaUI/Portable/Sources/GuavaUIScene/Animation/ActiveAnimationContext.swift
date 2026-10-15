import GuavaUICore
import Foundation

// MARK: - Completion criteria

/// When a `withAnimation` completion callback should run.
///
/// Mirrors SwiftUI's `AnimationCompletionCriteria` so the call-site idiom
/// transfers directly.
public enum AnimationCompletionCriteria: Sendable, Equatable {
    /// The animation reached the value it was animating toward.
    case logicallyComplete
    /// Every controller has stopped, including a spring's settling tail.
    case removed
}

// MARK: - Completion group

/// One `withAnimation` completion callback, plus the controllers it is waiting
/// on.
///
/// A single `withAnimation` body can invalidate several scopes, and each one
/// registers its own controllers when it commits. The group therefore cannot
/// fire the moment it looks empty — a later scope in the same `commitAll`
/// sweep may still add work. It fires from `AnimatorScheduler.tick` instead,
/// after the sweep that ran the last controller: every scope the mutation
/// triggered has committed by then, because commits all happen before any
/// tick.
public final class AnimationCompletionGroup {
    private let criteria: AnimationCompletionCriteria
    private let handler: () -> Void
    private var outstanding = 0
    private var settled = false
    private var cancelled = false
    var onSettlement: (() -> Void)?

    public var hasSettled: Bool { settled }

    public init(criteria: AnimationCompletionCriteria, handler: @escaping () -> Void) {
        self.criteria = criteria
        self.handler = handler
    }

    /// Account for a controller this group is waiting on.
    ///
    /// Generic over the animated value because that is what actually carries a
    /// completion report: the scheduler protocol is also implemented by clocks
    /// and timers, and none of those can finish an animated scope.
    public func attach<Value: Interpolatable>(_ controller: AnimationController<Value>) {
        guard !settled else { return }
        outstanding += 1
        // A zero-duration controller is already finished by the time it can be
        // attached. Wiring `onFinish` would wait for a tick that will never
        // report it, so settle the count now instead.
        if controller.isFinished || (criteria == .logicallyComplete && controller.isLogicallyFinished) {
            outstanding -= 1
            return
        }
        let completed = { [weak self] in
            guard let self, self.outstanding > 0 else { return }
            self.outstanding -= 1
        }
        if criteria == .logicallyComplete { controller.onLogicalFinish = completed }
        else {
            let previous = controller.onFinish
            controller.onFinish = { previous?(); completed() }
        }
        controller.onCancel = { [weak self] in
            self?.cancelled = true; self?.settled = true; self?.onSettlement?()
        }
    }

    /// Fire if nothing is outstanding. Called by the scheduler after a sweep.
    public func settleIfIdle() {
        guard !settled, outstanding == 0 else { return }
        settled = true
        onSettlement?()
        if !cancelled { handler() }
    }
}

// MARK: - Active animation context

/// Per-frame context that records the `Animation` (if any) under which the
/// current recomposition is running, plus the completion callback waiting on
/// it. Modifier `apply` paths read `current` when they detect that a node
/// property is changing, and — if non-nil — register an `AnimationController`
/// instead of writing the new value directly.
///
/// The context is established by `withAnimation(_:_:completion:)` at the call
/// site of a `@State` mutation. The runtime captures this value alongside the
/// queued recompose body, then re-establishes it inside
/// `Recomposer.commitAll()` so the modifier pass observes the same animation
/// that the user authored.
///
/// Storage is per-thread (via `Thread.current.threadDictionary`) so that
/// parallel test runners — and any future multi-window UI thread — observe
/// independent contexts. UI work in production all runs on a single thread
/// so the per-thread cost is amortised.
public enum ActiveAnimationContext {

    private static let storageKey = "guava.ui.ActiveAnimationContext"

    /// Box wrapper because `Animation` is a value type and
    /// `threadDictionary` requires `AnyObject` values.
    private final class Box {
        var value: Animation?
        var completion: AnimationCompletionGroup?
        var disablesAnimations = false
        init(_ v: Animation?) { value = v }
    }

    private static var box: Box {
        let dict = Thread.current.threadDictionary
        if let existing = dict[storageKey] as? Box { return existing }
        let fresh = Box(nil)
        dict[storageKey] = fresh
        return fresh
    }

    /// The animation in effect for the currently-running recompose, or `nil`
    /// when no animation is active. Reads outside `with(_:_:)` always return
    /// `nil` so non-animated writes remain instantaneous.
    public static var current: Animation? {
        box.value
    }

    /// The completion waiting on the in-flight animation, if the caller
    /// supplied one. Read by `animatableSet` so every controller the
    /// mutation creates is accounted for by the same callback.
    public static var currentCompletion: AnimationCompletionGroup? {
        box.completion
    }
    public static var disablesAnimations: Bool { box.disablesAnimations }

    /// Push `animation` as the active context for the duration of `body`,
    /// then restore the previous value. Nested calls stack; the innermost
    /// `withAnimation` wins.
    @discardableResult
    public static func with<R>(_ animation: Animation?, _ body: () throws -> R) rethrows -> R {
        try with(animation, completion: nil, body)
    }

    /// As above, carrying a completion callback alongside the animation.
    /// Both are captured and restored together so a nested `withAnimation`
    /// cleanly replaces or drops an outer completion.
    @discardableResult
    public static func with<R>(_ animation: Animation?,
                               completion: AnimationCompletionGroup?,
                               disablesAnimations: Bool? = nil,
                               _ body: () throws -> R) rethrows -> R {
        let storage = box
        let savedAnimation = storage.value
        let savedCompletion = storage.completion
        let savedDisabled = storage.disablesAnimations
        storage.value = animation
        storage.completion = completion
        storage.disablesAnimations = disablesAnimations ?? (animation == nil)
        defer {
            storage.value = savedAnimation
            storage.completion = savedCompletion
            storage.disablesAnimations = savedDisabled
        }
        return try body()
    }
}
