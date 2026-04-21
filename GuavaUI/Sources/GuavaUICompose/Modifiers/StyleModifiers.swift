import GuavaUIRuntime

enum StyleAttachmentKey {
    static let font = "__font"
    static let lineHeight = "__line_height"
}

public struct BackgroundModifier: ViewModifier {
    public let color: Color
    public init(_ color: Color) { self.color = color }

    public func apply(node: Node) {
        node.animatableSet(\.backgroundColor, to: color)
    }
}

public struct ForegroundColorModifier: ViewModifier {
    public let color: Color
    public init(_ color: Color) { self.color = color }

    public func apply(node: Node) {
        node.animatableSet(\.foregroundColor, to: color)
    }
}

public struct OpacityModifier: ViewModifier {
    public let opacity: Float
    public init(_ opacity: Float) {
        self.opacity = max(0, min(1, opacity))
    }

    public func apply(node: Node) {
        node.animatableSet(\.opacity, to: opacity)
    }
}

public struct ClipModifier: ViewModifier {
    public init() {}
    public func apply(node: Node) {
        node.clipsToBounds = true
    }
}

public struct CornerRadiusModifier: ViewModifier {
    public let radius: Float
    public init(_ radius: Float) { self.radius = max(0, radius) }

    public func apply(node: Node) {
        node.animatableSet(\.cornerRadius, to: radius)
    }
}

public struct BorderModifier: ViewModifier {
    public let color: Color
    public let width: Float
    public init(_ color: Color, width: Float) {
        self.color = color
        self.width = max(0, width)
    }

    public func apply(node: Node) {
        node.animatableSet(\.borderColor, to: color)
        node.animatableSet(\.borderWidth, to: width)
    }
}

public struct ShadowModifier: ViewModifier {
    public let color: Color
    public let offsetX: Float
    public let offsetY: Float
    public let blur: Float

    public init(color: Color, offsetX: Float, offsetY: Float, blur: Float) {
        self.color = color
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.blur = blur
    }

    public func apply(node: Node) {
        node.animatableSet(\.shadowColor, to: color)
        node.shadowOffsetX = offsetX
        node.shadowOffsetY = offsetY
        node.animatableSet(\.shadowBlur, to: blur)
    }
}

public struct FontModifier: ViewModifier {
    public let font: Font
    public init(_ font: Font) { self.font = font }

    public func apply(node: Node) {
        node.attachments[StyleAttachmentKey.font] = font
    }

    public func apply(layout: LayoutNode) {
        layout.attachments[StyleAttachmentKey.font] = font
        if layout.hasMeasureFunc { layout.markDirty() }
    }
}

/// Per-node line-height override consumed by `Text` (and `TextField`) at draw
/// time via `Node.attachments["__line_height"]`.
public struct LineHeightModifier: ViewModifier {
    public let lineHeight: Float
    public init(_ lineHeight: Float) { self.lineHeight = max(0, lineHeight) }

    public func apply(node: Node) {
        node.attachments[StyleAttachmentKey.lineHeight] = lineHeight
    }

    public func apply(layout: LayoutNode) {
        layout.attachments[StyleAttachmentKey.lineHeight] = lineHeight
        if layout.hasMeasureFunc { layout.markDirty() }
    }
}

public extension View {
    func background(_ color: Color) -> some View {
        modifier(BackgroundModifier(color))
    }

    func foregroundColor(_ color: Color) -> some View {
        modifier(ForegroundColorModifier(color))
    }

    func opacity(_ value: Float) -> some View {
        modifier(OpacityModifier(value))
    }

    func clipped() -> some View {
        modifier(ClipModifier())
    }

    func cornerRadius(_ radius: Float) -> some View {
        modifier(CornerRadiusModifier(radius))
    }

    func border(_ color: Color, width: Float = 1) -> some View {
        modifier(BorderModifier(color, width: width))
    }

    func shadow(color: Color,
                offsetX: Float = 0,
                offsetY: Float = 0,
                blur: Float = 0) -> some View {
        modifier(ShadowModifier(color: color,
                                offsetX: offsetX,
                                offsetY: offsetY,
                                blur: blur))
    }

    func font(_ font: Font) -> some View {
        modifier(FontModifier(font))
    }

    func lineHeight(_ value: Float) -> some View {
        modifier(LineHeightModifier(value))
    }
}
