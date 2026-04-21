import Foundation

/// Per-frame context that records the `Animation` (if any) under which the
/// current recomposition is running. Modifier `apply` paths read
/// `current` when they detect that a node property is changing, and
/// — if non-nil — register an `AnimationController` instead of writing the
/// new value directly.
///
/// The context is established by `withAnimation(_:_:)` at the call site of a
/// `@State` mutation. The runtime captures this value alongside the queued
/// recompose body, then re-establishes it inside `Recomposer.commitAll()`
/// so the modifier pass observes the same animation that the user authored.
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

    /// Push `animation` as the active context for the duration of `body`,
    /// then restore the previous value. Nested calls stack; the innermost
    /// `withAnimation` wins.
    @discardableResult
    public static func with<R>(_ animation: Animation?, _ body: () -> R) -> R {
        let storage = box
        let saved = storage.value
        storage.value = animation
        defer { storage.value = saved }
        return body()
    }
}
