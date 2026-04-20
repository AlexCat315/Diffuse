import GuavaUIRuntime

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
}
