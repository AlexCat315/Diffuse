import GuavaUIRuntime

/// An open, late-bound numeric token. Application roles can read their own
/// ThemeExtension without adding cases to a framework enum.
public struct ThemeMetric: Sendable {
    let resolve: @Sendable (Theme) -> Float
    public init(_ resolve: @escaping @Sendable (Theme) -> Float) { self.resolve = resolve }
    public static let contentSpacing = Self { $0.spacing.lg }
    public static let sectionSpacing = Self { $0.spacing.xxl }
    public static let rowRadius = Self { $0.radius.sm }
    public static let inputRadius = Self { $0.inputs.radius }
    public static let controlRadius = Self { $0.radius.md }
    public static let groupRadius = Self { $0.radius.lg }
    public static let panelRadius = Self { $0.radius.xl }
}

public extension View {
    func padding(_ token: ThemeMetric) -> some View {
        ThemeReader { theme in self.padding(token.resolve(theme)) }
    }
    func cornerRadius(_ token: ThemeMetric) -> some View {
        ThemeReader { theme in self.cornerRadius(token.resolve(theme)) }
    }
}
