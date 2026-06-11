import GuavaUIRuntime

/// Themed square SVG icon: the asset's alpha channel is used as coverage and
/// the foreground color as fill (`renderingMode: .alphaMask`), so icons follow
/// theme tokens instead of their source colors. Replaces the repeated
/// `Image(resource:width:height:tint:contentMode:renderingMode:)` incantation.
///
/// ```swift
/// Icon(UICommonIcons.chevronDown, size: 8, color: .onSurfaceMuted)
/// Icon(WorkspaceIcons.pinDot, size: 6, color: titleColor)
/// ```
public struct Icon: View {
    private enum Fill {
        case semantic(SemanticColorRef)
        case concrete(Color)
    }

    private let resource: BundleImageResource
    private let size: Float
    private let fill: Fill

    public init(_ resource: BundleImageResource,
                size: Float,
                color: SemanticColorRef = .onSurface) {
        self.resource = resource
        self.size = size
        self.fill = .semantic(color)
    }

    public init(_ resource: BundleImageResource,
                size: Float,
                color: Color) {
        self.resource = resource
        self.size = size
        self.fill = .concrete(color)
    }

    public var body: AnyView {
        let image = Image(resource: resource,
                          width: size,
                          height: size,
                          tint: .white,
                          contentMode: .fit,
                          renderingMode: .alphaMask)
        switch fill {
        case .semantic(let ref):
            return AnyView(image.foregroundColor(ref))
        case .concrete(let color):
            return AnyView(image.foregroundColor(color))
        }
    }
}
