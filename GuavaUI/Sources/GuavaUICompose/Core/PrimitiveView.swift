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
/// - `_makeLayoutNode()` creates the paired `LayoutNode` (Phase 6.3+). Return
///   `nil` only for views that don't participate in layout.
/// - `_updateLayout(_:)` writes layout-affecting properties onto the layout node.
/// - `_children` returns nested views to materialise as children of the produced
///   node. Empty for leaf primitives.
public protocol _PrimitiveView: View where Body == Never {
    func _makeNode() -> Node
    func _updateNode(_ node: Node)
    func _makeLayoutNode() -> LayoutNode?
    func _updateLayout(_ layout: LayoutNode)
    var _children: [any View] { get }

    /// Optional node-aware children list. Called by the materialiser after the
    /// produced node has been parented, so primitives may consult
    /// `Node.compositionValue(of:)` / `Node.theme` to decide what children to
    /// produce. Defaults to returning `_children` unchanged.
    func _children(for node: Node) -> [any View]
}

public extension _PrimitiveView {
    var _children: [any View] { [] }
    var body: Never { fatalError("_PrimitiveView has no body") }

    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateLayout(_ layout: LayoutNode) { /* default: no styling */ }

    func _children(for node: Node) -> [any View] { _children }
}
