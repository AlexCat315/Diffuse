import GuavaUIRuntime

public struct FlexModifier: ViewModifier {
    public let grow: Float
    public let shrink: Float
    public let basis: Float?

    public init(grow: Float = 1,
                shrink: Float = 1,
                basis: Float? = nil) {
        self.grow = grow
        self.shrink = shrink
        self.basis = basis
    }

    public func apply(layout: LayoutNode) {
        layout.flexGrow = grow
        layout.flexShrink = shrink
        if let basis {
            layout.setFlexBasis(basis)
        }
    }
}

public extension View {
    func flex(_ grow: Float = 1,
              shrink: Float = 1,
              basis: Float? = nil) -> some View {
        modifier(FlexModifier(grow: grow, shrink: shrink, basis: basis))
    }
}