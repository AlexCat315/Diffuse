import GuavaUIRuntime

/// Resolves the active theme while constructing content (for syntax colors
/// and other palettes that cannot be expressed as a single semantic token).
public struct ThemeReader<Content: View>: _PrimitiveView {
    private let content: (Theme) -> Content
    public init(@ViewBuilder content: @escaping (Theme) -> Content) { self.content = content }
    public func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }
    public func _updateNode(_ node: Node) {}
    // Reading an environment must not insert an extra layout container that
    // prevents a flex editor from filling the space assigned by its parent.
    public func _makeLayoutNode() -> LayoutNode? { nil }
    public func _children(for node: Node) -> [any View] { [content(node.theme)] }
}
