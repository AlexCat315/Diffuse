import GuavaUIRuntime

/// Themed square SVG icon: the asset's alpha channel is used as coverage and
/// the foreground color as fill (`renderingMode: .alphaMask`), so icons follow
/// theme tokens instead of their source colors. Replaces the repeated
/// `Image(resource:width:height:tint:contentMode:renderingMode:)` incantation.
///
/// ```swift
/// Icon(UIIcons.Navigation.chevronDown, size: 8, color: .onSurfaceMuted)
/// Icon(WorkspaceIcons.pinDot, size: 6, color: titleColor)
/// ```
public struct Icon: View {
    private enum Fill {
        case inherited
        case semantic(SemanticColorRef)
        case concrete(Color)
    }

    private let resource: BundleImageResource
    private enum Size { case points(Float), semantic(SemanticIconSize) }
    private let size: Size
    private let fill: Fill

    public init(_ resource: BundleImageResource,
                size: Float,
                color: SemanticColorRef? = nil) {
        self.resource = resource
        self.size = .points(size)
        self.fill = color.map(Fill.semantic) ?? .inherited
    }

    public init(_ resource: BundleImageResource,
                size: Float,
                color: Color) {
        self.resource = resource
        self.size = .points(size)
        self.fill = .concrete(color)
    }

    public init(_ resource: BundleImageResource, size: SemanticIconSize = .medium, color: SemanticColorRef? = nil) {
        self.resource = resource
        self.size = .semantic(size)
        self.fill = color.map(Fill.semantic) ?? .inherited
    }

    public init(_ resource: BundleImageResource, size: SemanticIconSize, color: Color) {
        self.resource = resource
        self.size = .semantic(size)
        self.fill = .concrete(color)
    }

    public var body: some View {
        ThemeReader { theme in
            IconMetricsReader { metrics in
                let resolved: Float = switch size {
                case .points(let value): metrics.size(value)
                case .semantic(let role): metrics.size(role)
                }
                // Keep layout slots/padding separate from the SVG's own size.
                // A surrounding .frame is a container, not a glyph resize.
                Box(direction: .row, alignItems: .center, justifyContent: .center) {
                    image(resource: theme.icons.resolve(resource), size: resolved)
                }
            }
        }
    }

    private func image(resource: BundleImageResource, size: Float) -> AnyView {

        let image = Image(resource: resource,
                          width: size,
                          height: size,
                          tint: .white,
                          contentMode: .fit,
                          renderingMode: .alphaMask)
        switch fill {
        case .inherited:
            return AnyView(image)
        case .semantic(let ref):
            return AnyView(image.foregroundColor(ref))
        case .concrete(let color):
            return AnyView(image.foregroundColor(color))
        }
    }
}
