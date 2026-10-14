import GuavaUIScene

public enum SurfaceEnvironment {
    public static let key = CompositionLocal<UIEnvironment>(defaultValue: UIEnvironment())
}

/// Reads per-surface capabilities without coupling content to a native host.
public struct SurfaceReader<Content: View>: _PrimitiveView {
    private let content: (UIEnvironment) -> Content
    public init(@ViewBuilder content: @escaping (UIEnvironment) -> Content) { self.content = content }
    public func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    public func _updateNode(_ node: Node) {}
    public func _makeLayoutNode() -> LayoutNode? { nil }
    public func _children(for node: Node) -> [any View] { [content(node.compositionValue(of: SurfaceEnvironment.key))] }
}

public extension View {
    /// Usually provided by the application host; override for previews or an embedded surface.
    func surfaceEnvironment(_ environment: UIEnvironment) -> some View {
        compositionLocal(SurfaceEnvironment.key, environment)
    }
}
