import GuavaUIRuntime

enum StyleAttachmentKey {
    static let font = "__font"
    static let lineHeight = "__line_height"
}

public struct BackgroundModifier: ViewModifier {
    public let color: Color
    public init(_ color: Color) { self.color = color }

    public func apply(node: Node) {
        node.backgroundColor = color
    }
}

public struct ForegroundColorModifier: ViewModifier {
    public let color: Color
    public init(_ color: Color) { self.color = color }

    public func apply(node: Node) {
        node.foregroundColor = color
    }
}

public struct OpacityModifier: ViewModifier {
    public let opacity: Float
    public init(_ opacity: Float) {
        self.opacity = max(0, min(1, opacity))
    }

    public func apply(node: Node) {
        node.opacity = opacity
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
        node.cornerRadius = radius
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
        layout.markDirty()
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
        layout.markDirty()
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

    func font(_ font: Font) -> some View {
        modifier(FontModifier(font))
    }

    func lineHeight(_ value: Float) -> some View {
        modifier(LineHeightModifier(value))
    }
}
