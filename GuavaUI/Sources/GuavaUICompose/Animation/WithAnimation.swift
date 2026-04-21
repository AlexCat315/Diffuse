import GuavaUIRuntime

/// Run `body` with `animation` installed as the active animation context.
///
/// State mutations performed inside `body` capture this animation; when the
/// resulting recompose runs, modifier `apply` paths that touch animatable
/// node properties register an `AnimationController` instead of writing the
/// new value instantly. Pass `nil` to explicitly disable animation for a
/// scope nested inside another animated scope.
///
/// Mirrors SwiftUI's `withAnimation(_:_:)` shape so the call-site idiom
/// transfers directly.
@discardableResult
public func withAnimation<R>(_ animation: Animation?, _ body: () -> R) -> R {
    ActiveAnimationContext.with(animation, body)
}
