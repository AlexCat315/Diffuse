import GuavaUIRuntime

public struct FrameModifier: ViewModifier {
    public let width: Float?
    public let height: Float?

    public init(width: Float? = nil, height: Float? = nil) {
        self.width = width
        self.height = height
    }

    public func apply(layout: LayoutNode) {
        if let w = width  { layout.width = w }
        if let h = height { layout.height = h }
    }
}

public extension View {
    func frame(width: Float? = nil, height: Float? = nil) -> some View {
        modifier(FrameModifier(width: width, height: height))
    }
}

