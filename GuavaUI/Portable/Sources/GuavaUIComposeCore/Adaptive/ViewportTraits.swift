import GuavaUIScene

/// Reads only the surface height class into application content.
public struct HeightClassReader<Content: View>: _PrimitiveView {
    private let content: (UIEnvironment.HeightClass) -> Content
    public init(@ViewBuilder content: @escaping (UIEnvironment.HeightClass) -> Content) { self.content = content }
    public func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    public func _updateNode(_ node: Node) {}
    public func _makeLayoutNode() -> LayoutNode? { nil }
    public func _children(for node: Node) -> [any View] {
        [content(node.compositionValue(of: SurfaceEnvironment.key).viewport.heightClass)]
    }
}

/// Reads whether the surface is portrait or landscape. Square counts as
/// landscape.
public struct OrientationReader<Content: View>: _PrimitiveView {
    private let content: (UIEnvironment.Orientation) -> Content
    public init(@ViewBuilder content: @escaping (UIEnvironment.Orientation) -> Content) { self.content = content }
    public func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    public func _updateNode(_ node: Node) {}
    public func _makeLayoutNode() -> LayoutNode? { nil }
    public func _children(for node: Node) -> [any View] {
        [content(node.compositionValue(of: SurfaceEnvironment.key).viewport.orientation)]
    }
}
