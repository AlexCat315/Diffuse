import GuavaUIScene

/// Reads only the surface width class into application content.
public struct WidthClassReader<Content: View>: _PrimitiveView {
    private let content: (UIEnvironment.WidthClass) -> Content
    public init(@ViewBuilder content: @escaping (UIEnvironment.WidthClass) -> Content) { self.content = content }
    public func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    public func _updateNode(_ node: Node) {}
    public func _makeLayoutNode() -> LayoutNode? { nil }
    public func _children(for node: Node) -> [any View] {
        [content(node.compositionValue(of: SurfaceEnvironment.key).viewport.widthClass)]
    }
}
