import GuavaUIRuntime

public enum FrameDimension: Equatable, Sendable {
    case points(Float)
    case percent(Float)
    case auto
}

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

/// Omitted dimensions preserve the content's own sizing. Use `.auto` to
/// explicitly return an axis to intrinsic sizing.
public struct FrameModifier: ViewModifier {
    public let width: FrameDimension?
    public let height: FrameDimension?
    public let minWidth: Float?
    public let minHeight: Float?
    public let maxWidth: Float?
    public let maxHeight: Float?

    public init(width: FrameDimension? = nil, height: FrameDimension? = nil,
                minWidth: Float? = nil, minHeight: Float? = nil,
                maxWidth: Float? = nil, maxHeight: Float? = nil) {
        self.width = width; self.height = height
        self.minWidth = minWidth; self.minHeight = minHeight
        self.maxWidth = maxWidth; self.maxHeight = maxHeight
    }

    private func spec(_ dimension: FrameDimension) -> FrameDimensionSpec {
        switch dimension {
        case .auto: .auto
        case .points(let value): .points(value)
        case .percent(let value): .percent(value)
        }
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

        let currentWidth = (layout.attachments[FrameAttachmentKey.widthSpec] as? FrameDimensionSpec)
            ?? (layout.width.map { .points($0) } ?? .auto)
        let currentHeight = (layout.attachments[FrameAttachmentKey.heightSpec] as? FrameDimensionSpec)
            ?? (layout.height.map { .points($0) } ?? .auto)

        if let width {
            let targetWidth = spec(width)
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
        }
        if let height {
            let targetHeight = spec(height)
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
        }
        if let minWidth {
            node.animatableSet(propertyKey: FrameAnimationPropertyKey.minWidth,
                               current: layout.minWidth, to: minWidth) { layout.minWidth = $0 }
        }
        if let minHeight {
            node.animatableSet(propertyKey: FrameAnimationPropertyKey.minHeight,
                               current: layout.minHeight, to: minHeight) { layout.minHeight = $0 }
        }
        if let maxWidth {
            node.animatableSet(propertyKey: FrameAnimationPropertyKey.maxWidth,
                               current: layout.maxWidth, to: maxWidth) { layout.maxWidth = $0 }
        }
        if let maxHeight {
            node.animatableSet(propertyKey: FrameAnimationPropertyKey.maxHeight,
                               current: layout.maxHeight, to: maxHeight) { layout.maxHeight = $0 }
        }
    }

    public func apply(layout: LayoutNode) {
        // Layout-affecting writes flow through `apply(node:)` so they can
        // participate in `withAnimation` and `.animation(_:value:)`.
    }
}

public extension View {
    @_disfavoredOverload
    func frame(width: FrameDimension? = nil,
               height: FrameDimension? = nil,
               minWidth: Float? = nil,
               minHeight: Float? = nil,
               maxWidth: Float? = nil,
               maxHeight: Float? = nil) -> some View {
        modifier(FrameModifier(width: width, height: height,
                               minWidth: minWidth, minHeight: minHeight,
                               maxWidth: maxWidth, maxHeight: maxHeight))
    }

    func framePercent(width: Float? = nil,
                      height: Float? = nil,
                      minWidth: Float? = nil,
                      minHeight: Float? = nil,
                      maxWidth: Float? = nil,
                      maxHeight: Float? = nil) -> some View {
        frame(width: width.map { .percent($0) },
              height: height.map { .percent($0) },
              minWidth: minWidth,
              minHeight: minHeight,
              maxWidth: maxWidth,
              maxHeight: maxHeight)
    }

    func frame(width: Float? = nil,
               height: Float? = nil,
               minWidth: Float? = nil,
               minHeight: Float? = nil,
               maxWidth: Float? = nil,
               maxHeight: Float? = nil) -> some View {
        modifier(FrameModifier(width: width.map { .points($0) }, height: height.map { .points($0) },
                               minWidth: minWidth, minHeight: minHeight,
                               maxWidth: maxWidth, maxHeight: maxHeight))
    }
}
