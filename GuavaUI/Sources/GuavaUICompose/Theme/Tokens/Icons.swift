import GuavaUIRuntime

public struct IconTheme: Sendable {
    public var small: Float = 12
    public var medium: Float = 16
    public var large: Float = 24
    public var scaling: IconScaling = .text
    private var replacements: [String: BundleImageResource] = [:]
    public init(configure: (inout Self) -> Void = { _ in }) { configure(&self) }
    public mutating func replace(_ resource: BundleImageResource, with replacement: BundleImageResource) {
        replacements[resource.description] = replacement
    }
    func resolve(_ resource: BundleImageResource) -> BundleImageResource { replacements[resource.description] ?? resource }
}

/// Icon sizes use logical points. Accessibility text scaling also enlarges
/// icons by default; fixed artwork or a custom design system can override it.
public enum IconScaling: Hashable, Sendable {
    case text
    case fixed
    case factor(Float)
}

private enum IconScalingEnvironment {
    static let key = CompositionLocal<IconScaling?>(defaultValue: nil)
}

/// Resolves icon and slot geometry with the same policy. Display density is
/// handled by the renderer and must never be multiplied into these values.
public struct IconMetrics {
    private let theme: Theme
    public let factor: Float
    init(node: Node) {
        theme = node.theme
        switch node.compositionValue(of: IconScalingEnvironment.key) ?? theme.icons.scaling {
        case .text: factor = node.textScaler.factor
        case .fixed: factor = 1
        case .factor(let value): factor = TextScaler(value).factor
        }
    }
    public func size(_ points: Float) -> Float {
        let points = points.isFinite ? max(1, points) : 16
        return points * factor
    }
    public func size(_ role: SemanticIconSize) -> Float { size(role.resolve(theme)) }
}

public struct IconMetricsReader<Content: View>: _PrimitiveView {
    private let content: (IconMetrics) -> Content
    public init(@ViewBuilder content: @escaping (IconMetrics) -> Content) { self.content = content }
    public func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    public func _updateNode(_ node: Node) {}
    public func _makeLayoutNode() -> LayoutNode? { nil }
    public func _children(for node: Node) -> [any View] { [content(IconMetrics(node: node))] }
}

public extension View {
    /// Overrides this subtree's icon policy without changing its typography.
    func iconScaling(_ scaling: IconScaling) -> some View {
        compositionLocal(IconScalingEnvironment.key, scaling)
    }
}

extension Node {
    var iconMetrics: IconMetrics { IconMetrics(node: self) }
    var iconScalingOverride: IconScaling? { compositionValue(of: IconScalingEnvironment.key) }
}

/// Custom roles can resolve application-defined ThemeExtensions as well.
public struct SemanticIconSize: Sendable {
    let resolve: @Sendable (Theme) -> Float
    public init(_ resolve: @escaping @Sendable (Theme) -> Float) { self.resolve = resolve }
    public static let small = Self { $0.icons.small }
    public static let medium = Self { $0.icons.medium }
    public static let large = Self { $0.icons.large }
}
