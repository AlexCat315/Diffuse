import GuavaUIRuntime

/// Run `body` with `animation` installed as the active animation context.
///
/// State mutations performed inside `body` capture this animation; when the
/// resulting recompose runs, modifier `apply` paths that touch animatable
/// node properties register an `AnimationController` instead of writing the
/// new value instantly.
///
/// Mirrors SwiftUI's `withAnimation(_:_:)` shape so the call-site idiom
/// transfers directly.
@discardableResult
public func withAnimation<R>(_ animation: Animation = .default,
                             _ body: () throws -> R) rethrows -> R {
    try ActiveAnimationContext.with(animation, body)
}

/// Run `body` with an optional animation context.
///
/// Pass `nil` to explicitly disable animation for a nested scope.
@discardableResult
public func withAnimation<R>(_ animation: Animation?,
                             _ body: () throws -> R) rethrows -> R {
    try ActiveAnimationContext.with(animation, body)
}
