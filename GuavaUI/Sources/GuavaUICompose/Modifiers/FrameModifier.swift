import GuavaUIRuntime

private enum FrameAnimationPropertyKey {
    static let width = "__layout.frame.width"
    static let height = "__layout.frame.height"
    static let minWidth = "__layout.frame.minWidth"
    static let minHeight = "__layout.frame.minHeight"
    static let maxWidth = "__layout.frame.maxWidth"
    static let maxHeight = "__layout.frame.maxHeight"
}

private enum FrameAttachmentKey {
    static let widthSpec = "__layout.frame.widthSpec"
    static let heightSpec = "__layout.frame.heightSpec"
}

private enum FrameDimensionSpec: Equatable {
    case auto
    case points(Float)
    case percent(Float)
}

public struct FrameModifier: ViewModifier {
    public let width: Float?
    public let height: Float?
    public let widthPercent: Float?
    public let heightPercent: Float?
    public let minWidth: Float?
    public let minHeight: Float?
    public let maxWidth: Float?
    public let maxHeight: Float?

    public init(width: Float? = nil,
                height: Float? = nil,
                widthPercent: Float? = nil,
                heightPercent: Float? = nil,
                minWidth: Float? = nil,
                minHeight: Float? = nil,
                maxWidth: Float? = nil,
                maxHeight: Float? = nil) {
        precondition(width == nil || widthPercent == nil,
                     "frame(width:widthPercent:) does not allow both width and widthPercent")
        precondition(height == nil || heightPercent == nil,
                     "frame(height:heightPercent:) does not allow both height and heightPercent")
        self.width = width
        self.height = height
        self.widthPercent = widthPercent
        self.heightPercent = heightPercent
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }

    private func widthSpec() -> FrameDimensionSpec {
        if let value = widthPercent { return .percent(value) }
        if let value = width { return .points(value) }
        return .auto
    }

    private func heightSpec() -> FrameDimensionSpec {
        if let value = heightPercent { return .percent(value) }
        if let value = height { return .points(value) }
        return .auto
    }

    private func applyWidth(_ spec: FrameDimensionSpec, to layout: LayoutNode) {
        switch spec {
        case .auto:
            layout.width = nil
        case .points(let value):
            layout.width = value
        case .percent(let value):
            layout.setWidthPercent(value)
        }
        layout.attachments[FrameAttachmentKey.widthSpec] = spec
    }

    private func applyHeight(_ spec: FrameDimensionSpec, to layout: LayoutNode) {
        switch spec {
        case .auto:
            layout.height = nil
        case .points(let value):
            layout.height = value
        case .percent(let value):
            layout.setHeightPercent(value)
        }
        layout.attachments[FrameAttachmentKey.heightSpec] = spec
    }

    public func apply(node: Node) {
        guard let layout = node.layoutNode else { return }
        let targetWidth = widthSpec()
        let targetHeight = heightSpec()

        let currentWidth = (layout.attachments[FrameAttachmentKey.widthSpec] as? FrameDimensionSpec)
            ?? (layout.width.map { .points($0) } ?? .auto)
        let currentHeight = (layout.attachments[FrameAttachmentKey.heightSpec] as? FrameDimensionSpec)
            ?? (layout.height.map { .points($0) } ?? .auto)

        switch (currentWidth, targetWidth) {
        case (.points(let from), .points(let to)):
            node.animatableSet(propertyKey: FrameAnimationPropertyKey.width,
                               current: from,
                               to: to) { applyWidth(.points($0), to: layout) }
        case (.percent(let from), .percent(let to)):
            node.animatableSet(propertyKey: FrameAnimationPropertyKey.width,
                               current: from,
                               to: to) { applyWidth(.percent($0), to: layout) }
        default:
            node.cancelAnimation(for: FrameAnimationPropertyKey.width)
            applyWidth(targetWidth, to: layout)
        }

        switch (currentHeight, targetHeight) {
        case (.points(let from), .points(let to)):
            node.animatableSet(propertyKey: FrameAnimationPropertyKey.height,
                               current: from,
                               to: to) { applyHeight(.points($0), to: layout) }
        case (.percent(let from), .percent(let to)):
            node.animatableSet(propertyKey: FrameAnimationPropertyKey.height,
                               current: from,
                               to: to) { applyHeight(.percent($0), to: layout) }
        default:
            node.cancelAnimation(for: FrameAnimationPropertyKey.height)
            applyHeight(targetHeight, to: layout)
        }

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
               widthPercent: Float? = nil,
               heightPercent: Float? = nil,
               minWidth: Float? = nil,
               minHeight: Float? = nil,
               maxWidth: Float? = nil,
               maxHeight: Float? = nil) -> some View {
        modifier(FrameModifier(width: width,
                               height: height,
                               widthPercent: widthPercent,
                               heightPercent: heightPercent,
                               minWidth: minWidth,
                               minHeight: minHeight,
                               maxWidth: maxWidth,
                               maxHeight: maxHeight))
    }
}

