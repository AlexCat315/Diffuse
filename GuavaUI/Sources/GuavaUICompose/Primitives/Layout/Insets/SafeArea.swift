import GuavaUIRuntime

public struct SafeAreaEdges: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let top = Self(rawValue: 1 << 0)
    public static let leading = Self(rawValue: 1 << 1)
    public static let bottom = Self(rawValue: 1 << 2)
    public static let trailing = Self(rawValue: 1 << 3)
    public static let horizontal: Self = [.leading, .trailing]
    public static let vertical: Self = [.top, .bottom]
    public static let all: Self = [.horizontal, .vertical]
}

private enum SafeAreaEnvironment {
    static let insets = CompositionLocal<EdgeInsets>(defaultValue: .zero)
}

/// Insets supplied by the host are consumed once, by the selected logical
/// edges. Nested SafeArea containers receive only the remaining edges.
public struct SafeArea<Content: View>: _PrimitiveView {
    private let edges: SafeAreaEdges
    private let content: Content

    public init(_ edges: SafeAreaEdges = .all, @ViewBuilder content: () -> Content) {
        self.edges = edges
        self.content = content()
    }

    public func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    public func _updateNode(_ node: Node) {
        let insets = node.compositionValue(of: SafeAreaEnvironment.insets)
        guard let layout = node.layoutNode else { return }
        layout.setPadding(edges.contains(.top) ? valid(insets.top) : 0, edge: .top)
        layout.setPadding(edges.contains(.leading) ? valid(insets.leading) : 0, edge: .start)
        layout.setPadding(edges.contains(.bottom) ? valid(insets.bottom) : 0, edge: .bottom)
        layout.setPadding(edges.contains(.trailing) ? valid(insets.trailing) : 0, edge: .end)
    }

    public func _children(for node: Node) -> [any View] {
        var remaining = node.compositionValue(of: SafeAreaEnvironment.insets)
        if edges.contains(.top) { remaining.top = 0 }
        if edges.contains(.leading) { remaining.leading = 0 }
        if edges.contains(.bottom) { remaining.bottom = 0 }
        if edges.contains(.trailing) { remaining.trailing = 0 }
        return [content.compositionLocal(SafeAreaEnvironment.insets, remaining)]
    }

    private func valid(_ value: Float) -> Float { value.isFinite ? max(0, value) : 0 }
}

public extension View {
    /// Provide host insets in logical points. Desktop hosts default to zero;
    /// platform chrome/keyboard geometry must be supplied by the owning host.
    func safeAreaInsets(_ insets: EdgeInsets) -> some View {
        compositionLocal(SafeAreaEnvironment.insets, insets)
    }
}
