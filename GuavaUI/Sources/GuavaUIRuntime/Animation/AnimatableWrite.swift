import Foundation

// MARK: - Animatable property writes

/// Helpers for modifier `apply` paths that need to flow through the
/// animator when `withAnimation` is in scope, and write the value
/// instantaneously otherwise.
///
/// All paths follow the same shape:
/// 1. If `ActiveAnimationContext.current` is `nil`, write `target` directly
///    and return.
/// 2. Otherwise, snapshot the current value, build an `AnimationController`
///    whose `apply` closure writes through the same accessor, and register
///    it with `AnimatorScheduler.shared`.
///
/// Edge cases for `Optional<Value>` (e.g. `Color?`): if either endpoint is
/// `nil` we cannot meaningfully interpolate, so we fall back to an instant
/// write and skip the controller. Animating in/out of `nil` is the caller's
/// responsibility (e.g. wrap with an explicit transparent `Color`).

public extension Node {

    /// Animate (or instantly assign, depending on the active animation
    /// context) a property of type `Value`.
    @inline(__always)
    func animatableSet<Value: Interpolatable & Equatable>(
        _ keyPath: ReferenceWritableKeyPath<Node, Value>,
        to target: Value
    ) {
        let current = self[keyPath: keyPath]
        guard let anim = ActiveAnimationContext.current, current != target else {
            self[keyPath: keyPath] = target
            return
        }
        let controller = AnimationController(
            from: current,
            to: target,
            animation: anim,
            apply: { [weak self] v in self?[keyPath: keyPath] = v }
        )
        AnimatorScheduler.current.register(controller)
    }

    /// Optional-typed variant. Interpolation requires both endpoints to be
    /// non-`nil`; transitions in or out of `nil` snap.
    @inline(__always)
    func animatableSet<Value: Interpolatable & Equatable>(
        _ keyPath: ReferenceWritableKeyPath<Node, Value?>,
        to target: Value?
    ) {
        let current = self[keyPath: keyPath]
        guard let anim = ActiveAnimationContext.current,
              let from = current,
              let to = target,
              from != to
        else {
            self[keyPath: keyPath] = target
            return
        }
        let controller = AnimationController(
            from: from,
            to: to,
            animation: anim,
            apply: { [weak self] v in self?[keyPath: keyPath] = v }
        )
        AnimatorScheduler.current.register(controller)
    }
}
