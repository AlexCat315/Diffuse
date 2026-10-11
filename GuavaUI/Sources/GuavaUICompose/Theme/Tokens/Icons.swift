import GuavaUIRuntime

public struct IconTheme: Sendable {
    public var small: Float = 12
    public var medium: Float = 16
    public var large: Float = 24
    private var replacements: [String: BundleImageResource] = [:]
    public init(configure: (inout Self) -> Void = { _ in }) { configure(&self) }
    public mutating func replace(_ resource: BundleImageResource, with replacement: BundleImageResource) {
        replacements[resource.description] = replacement
    }
    func resolve(_ resource: BundleImageResource) -> BundleImageResource { replacements[resource.description] ?? resource }
}

/// Custom roles can resolve application-defined ThemeExtensions as well.
public struct SemanticIconSize: Sendable {
    let resolve: @Sendable (Theme) -> Float
    public init(_ resolve: @escaping @Sendable (Theme) -> Float) { self.resolve = resolve }
    public static let small = Self { $0.icons.small }
    public static let medium = Self { $0.icons.medium }
    public static let large = Self { $0.icons.large }
}
