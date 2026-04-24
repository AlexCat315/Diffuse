import GuavaUIRuntime

private enum FrameAnimationPropertyKey {
    static let width = "__layout.frame.width"
    static let height = "__layout.frame.height"
    static let minWidth = "__layout.frame.minWidth"
    static let minHeight = "__layout.frame.minHeight"
    static let maxWidth = "__layout.frame.maxWidth"
    static let maxHeight = "__layout.frame.maxHeight"
}

public struct FrameModifier: ViewModifier {
    public let width: Float?
    public let height: Float?
    public let minWidth: Float?
    public let minHeight: Float?
    public let maxWidth: Float?
    public let maxHeight: Float?

    public init(width: Float? = nil,
                height: Float? = nil,
                minWidth: Float? = nil,
                minHeight: Float? = nil,
                maxWidth: Float? = nil,
                maxHeight: Float? = nil) {
        self.width = width
        self.height = height
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }

    public func apply(node: Node) {
        guard let layout = node.layoutNode else { return }
        node.animatableSet(propertyKey: FrameAnimationPropertyKey.width,
                           current: layout.width,
                           to: width) { layout.width = $0 }
        node.animatableSet(propertyKey: FrameAnimationPropertyKey.height,
                           current: layout.height,
                           to: height) { layout.height = $0 }
        node.animatableSet(propertyKey: FrameAnimationPropertyKey.minWidth,
                           current: layout.minWidth,
                           to: minWidth) { layout.minWidth = $0 }
        node.animatableSet(propertyKey: FrameAnimationPropertyKey.minHeight,
                           current: layout.minHeight,
                           to: minHeight) { layout.minHeight = $0 }
        node.animatableSet(propertyKey: FrameAnimationPropertyKey.maxWidth,
                   current: layout.maxWidth,
                   to: maxWidth) { layout.maxWidth = $0 }
        node.animatableSet(propertyKey: FrameAnimationPropertyKey.maxHeight,
                   current: layout.maxHeight,
                   to: maxHeight) { layout.maxHeight = $0 }
    }

    public func apply(layout: LayoutNode) {
        // Layout-affecting writes flow through `apply(node:)` so they can
        // participate in `withAnimation` and `.animation(_:value:)`.
    }
}

public extension View {
    func frame(width: Float? = nil,
               height: Float? = nil,
               minWidth: Float? = nil,
               minHeight: Float? = nil,
               maxWidth: Float? = nil,
               maxHeight: Float? = nil) -> some View {
        modifier(FrameModifier(width: width,
                               height: height,
                               minWidth: minWidth,
                               minHeight: minHeight,
                               maxWidth: maxWidth,
                               maxHeight: maxHeight))
    }
}

