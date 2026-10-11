import GuavaUIRuntime

/// Text scaling is independent of display density and the application's
/// typography ramp. Hosts can supply their accessibility setting once at the
/// root; pages can override it. No rounding occurs in logical coordinates.
public struct TextScaler: Hashable, Sendable {
    public let factor: Float
    public init(_ factor: Float = 1) { self.factor = factor.isFinite && factor > 0 ? factor : 1 }
    public static let identity = TextScaler()
    public func scale(_ value: Float) -> Float { value * factor }
    public func scale(_ font: Font) -> Font {
        Font(size: scale(font.size), weight: font.weight, design: font.design, family: font.family)
    }
}

public enum TextScalerEnvironment {
    public static let key = CompositionLocal<TextScaler>(defaultValue: .identity)
}

struct TextScalerModifier: ViewModifier, _ScopeApplyingModifier {
    let scaler: TextScaler
    static let key = "__text_scaler"
    func _applyScope(node: Node) -> Bool {
        guard node.compositionValues[TextScalerEnvironment.key.key] as? TextScaler != scaler else { return false }
        node.setCompositionValue(TextScalerEnvironment.key, scaler)
        node.invalidateTextStyle()
        return true
    }
}

extension Node {
    /// Copy composition defaults to the measured leaf. Explicit font/style
    /// attachments anywhere in its ancestry retain priority over this fallback.
    func syncTextStyleEnvironment() {
        guard let layout = layoutNode else { return }
        let body = compositionValue(of: ThemeEnvironment.bodyStyle)
        let changed = layout.attachments[TextScalerModifier.key] as? TextScaler != textScaler
            || layout.attachments[ThemeEnvironment.bodyStyleAttachment] as? TextStyleToken != body
        layout.attachments[TextScalerModifier.key] = textScaler
        layout.attachments[ThemeEnvironment.bodyStyleAttachment] = body
        if changed { layout.invalidateTextMeasurements() }
    }
}

/// For layout with explicit row heights, resolve the same scale as text.
public struct TextScalerReader<Content: View>: _PrimitiveView {
    private let content: (TextScaler) -> Content
    public init(@ViewBuilder content: @escaping (TextScaler) -> Content) { self.content = content }
    public func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    public func _updateNode(_ node: Node) {}
    public func _makeLayoutNode() -> LayoutNode? { nil }
    public func _children(for node: Node) -> [any View] { [content(node.textScaler)] }
}

public extension View {
    func textScaler(_ scaler: TextScaler) -> some View { modifier(TextScalerModifier(scaler: scaler)) }
    func textStyle(_ token: TextStyleToken) -> some View { font(SemanticFontRef { _ in token }) }
}
