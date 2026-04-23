import GuavaUIRuntime

public struct FrameModifier: ViewModifier {
    public let width: Float?
    public let height: Float?
    public let minWidth: Float?
    public let minHeight: Float?

    public init(width: Float? = nil,
                height: Float? = nil,
                minWidth: Float? = nil,
                minHeight: Float? = nil) {
        self.width = width
        self.height = height
        self.minWidth = minWidth
        self.minHeight = minHeight
    }

    public func apply(layout: LayoutNode) {
        if let w = width  { layout.width = w }
        if let h = height { layout.height = h }
        if let minWidth { layout.minWidth = minWidth }
        if let minHeight { layout.minHeight = minHeight }
    }
}

public extension View {
    func frame(width: Float? = nil,
               height: Float? = nil,
               minWidth: Float? = nil,
               minHeight: Float? = nil) -> some View {
        modifier(FrameModifier(width: width,
                               height: height,
                               minWidth: minWidth,
                               minHeight: minHeight))
    }
}

