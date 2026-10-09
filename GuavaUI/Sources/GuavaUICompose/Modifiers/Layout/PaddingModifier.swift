import GuavaUIRuntime

private enum PaddingAnimationKeys {
    static let property = "__layout.padding.insets"
    static let attachment = "__layout.padding.insets"
}

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

    public func apply(node: Node) {
        guard let layout = node.layoutNode else { return }
        let current = (layout.attachments[PaddingAnimationKeys.attachment] as? EdgeInsets) ?? .zero
        node.animatableSet(propertyKey: PaddingAnimationKeys.property,
                           current: current,
                           to: insets) { value in
            layout.attachments[PaddingAnimationKeys.attachment] = value
            layout.setPadding(value.top, edge: .top)
            layout.setPadding(value.leading, edge: .left)
            layout.setPadding(value.bottom, edge: .bottom)
            layout.setPadding(value.trailing, edge: .right)
        }
    }

    public func apply(layout: LayoutNode) {
        // Layout-affecting writes flow through `apply(node:)` so they can
        // participate in `withAnimation` and `.animation(_:value:)`.
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
