import GuavaUIRuntime

/// Internal hook for views that materialise into a real `Node` (rather than
/// expanding to other views via `body`).
///
/// `Text` / `Image` / `Box` / `Row` / `Column` etc. (Phase 6.3) conform to this.
/// User-defined `View` types should never implement `_PrimitiveView` directly.
///
/// Conventions:
/// - `_makeNode()` creates a fresh `Node` (called once per scope per recompose).
/// - `_updateNode(_:)` writes view properties onto the node every materialisation.
/// - `_children` returns nested views to materialise as children of the produced
///   node. Empty for leaf primitives.
public protocol _PrimitiveView: View where Body == Never {
    func _makeNode() -> Node
    func _updateNode(_ node: Node)
    var _children: [any View] { get }
}

public extension _PrimitiveView {
    var _children: [any View] { [] }
    var body: Never { fatalError("_PrimitiveView has no body") }
}
