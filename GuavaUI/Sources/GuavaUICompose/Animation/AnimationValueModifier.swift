import GuavaUIRuntime

/// Internal modifier installed by `View.animation(_:value:)`.
///
/// On each materialise / update pass it caches the most recent `value` on a
/// dedicated synthetic anchor `Node` (allocated by the `_AroundApplyingModifier`
/// pathway). When the value differs from the previous pass, the descendant
/// re-render is wrapped in `ActiveAnimationContext.with(animation)` so any
/// `animatableSet` write encountered during recompose flows through the
/// scheduler — no explicit `withAnimation { ... }` required at the call site.
///
/// First materialisation always snaps (no previous value to compare against).
/// A `nil` animation suppresses the wrap even on value change, matching the
/// SwiftUI semantics where `.animation(nil, value:)` removes implicit
/// animation for the keyed value.
public struct _AnimationValueModifier<Value: Equatable>: ViewModifier, _AroundApplyingModifier {
    public typealias Body = _ViewModifier_Content<Self>

    private static var cacheKey: String { "guava.ui.animation.lastValue" }

    let animation: Animation?
    let value: Value

    public init(animation: Animation?, value: Value) {
        self.animation = animation
        self.value = value
    }

    public func _aroundApply(node: Node, perform: () -> Void) {
        let key = Self.cacheKey
        let previous = node.attachments[key] as? Value
        let changed = previous != nil && previous != value
        node.attachments[key] = value

        if changed, let anim = animation {
            ActiveAnimationContext.with(anim, perform)
        } else {
            perform()
        }
    }
}

public extension View {
    /// Apply `animation` to any animatable property change inside this subtree
    /// whenever `value` changes. Pass `nil` to disable implicit animation for
    /// this keyed value.
    ///
    /// The first render snaps; only subsequent value changes trigger the
    /// animation. Compose multiple `.animation(_:value:)` calls to key on
    /// different state (each call carries an independent cache).
    func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(_AnimationValueModifier(animation: animation, value: value))
    }
}
