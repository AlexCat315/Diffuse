import GuavaUIRuntime

/// Marker for `ViewModifier`s that need to wrap descendant materialisation —
/// installing some ambient state for the duration of the recursion and tearing
/// it down afterwards.
///
/// Like `_ScopeApplyingModifier`, the materialiser allocates a synthetic
/// anchor `Node` per slot so the modifier has a stable place to cache state
/// across recompose passes. The closure must be invoked exactly once — it is
/// what materialises (or reconciles) the wrapped content.
///
/// Routing rule: modifiers conforming to this protocol are NOT consulted via
/// `apply(node:)` / `apply(layout:)`. Their behaviour is delivered exclusively
/// through `_aroundApply(node:perform:)`.
public protocol _AroundApplyingModifier {
    func _aroundApply(node: Node, perform: () -> Void)
}
