import GuavaUIRuntime

public struct EdgeInsets: Equatable, Sendable {
    public var top: Float
    public var leading: Float
    public var bottom: Float
    public var trailing: Float

    public init(top: Float = 0, leading: Float = 0, bottom: Float = 0, trailing: Float = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }

    public init(all v: Float) {
        self.init(top: v, leading: v, bottom: v, trailing: v)
    }

    public static let zero = EdgeInsets()
}

public struct PaddingModifier: ViewModifier {
    public let insets: EdgeInsets
    public init(insets: EdgeInsets) { self.insets = insets }

    public func apply(layout: LayoutNode) {
        layout.setPadding(insets.top,      edge: .top)
        layout.setPadding(insets.leading,  edge: .left)
        layout.setPadding(insets.bottom,   edge: .bottom)
        layout.setPadding(insets.trailing, edge: .right)
    }
}

public extension View {
    func padding(_ value: Float) -> some View {
        modifier(PaddingModifier(insets: EdgeInsets(all: value)))
    }
    func padding(_ insets: EdgeInsets) -> some View {
        modifier(PaddingModifier(insets: insets))
    }
}
