import GuavaUIRuntime

/// Run `body` with `animation` installed as the active animation context.
///
/// State mutations performed inside `body` capture this animation; when the
/// resulting recompose runs, modifier `apply` paths that touch animatable
/// node properties register an `AnimationController` instead of writing the
/// new value instantly.
///
/// `completion` runs once every controller that mutation created has reached
/// its target — or on the first frame after the commit if the mutation turned
/// out to animate nothing. It does **not** run when a later animation
/// supersedes these controllers: an abandoned animation was interrupted, not
/// completed.
///
/// Mirrors SwiftUI's `withAnimation(_:_:completion:)` shape so the call-site
/// idiom transfers directly.
@discardableResult
public func withAnimation<R>(_ animation: Animation = .default,
                             completionCriteria: AnimationCompletionCriteria = .logicallyComplete,
                             _ body: () throws -> R,
                             completion: (() -> Void)? = nil) rethrows -> R {
    guard let completion else {
        return try ActiveAnimationContext.with(animation, body)
    }
    let group = AnimationCompletionGroup(criteria: completionCriteria, handler: completion)
    // Registered before the body runs so the callback can land on this frame's
    // sweep even when nothing animates — a mutation that changes no animatable
    // property still deserves its completion.
    AnimatorScheduler.current.track(group)
    return try ActiveAnimationContext.with(animation, completion: group, body)
}

/// Run `body` with an optional animation context.
///
/// Pass `nil` to explicitly disable animation for a nested scope. Supplying
/// `completion` installs a callback for this scope only; an outer
/// `withAnimation`'s callback is unaffected.
@discardableResult
public func withAnimation<R>(_ animation: Animation?,
                             completionCriteria: AnimationCompletionCriteria = .logicallyComplete,
                             _ body: () throws -> R,
                             completion: (() -> Void)? = nil) rethrows -> R {
    guard let completion else {
        return try ActiveAnimationContext.with(animation, body)
    }
    let group = AnimationCompletionGroup(criteria: completionCriteria, handler: completion)
    AnimatorScheduler.current.track(group)
    return try ActiveAnimationContext.with(animation, completion: group, body)
}