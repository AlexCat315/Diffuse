import GuavaUIRuntime

public struct AbsolutePositionModifier: ViewModifier {
    public let left: Float?
    public let top: Float?
    public let right: Float?
    public let bottom: Float?

    public init(left: Float? = nil,
                top: Float? = nil,
                right: Float? = nil,
                bottom: Float? = nil) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public func apply(node: Node) {
        guard let layout = node.layoutNode else { return }
        apply(to: layout)
    }

    public func apply(layout: LayoutNode) {
        apply(to: layout)
    }

    private func apply(to layout: LayoutNode) {
        layout.positionType = .absolute
        set(left, edge: .left, on: layout)
        set(top, edge: .top, on: layout)
        set(right, edge: .right, on: layout)
        set(bottom, edge: .bottom, on: layout)
    }

    private func set(_ value: Float?, edge: Edge, on layout: LayoutNode) {
        if let value {
            layout.setPosition(value, edge: edge)
        } else {
            layout.setPositionAuto(edge: edge)
        }
    }
}

public extension View {
    func absolutePosition(left: Float? = nil,
                          top: Float? = nil,
                          right: Float? = nil,
                          bottom: Float? = nil) -> some View {
        modifier(AbsolutePositionModifier(left: left,
                                          top: top,
                                          right: right,
                                          bottom: bottom))
    }
}
