import GuavaUIRuntime

/// A faint upper edge and a shallow shadow: material without glass or gradients.
///
/// For surfaces that sit *in* the chrome — a panel edge, a sidebar. Surfaces
/// that float above it want `glassSurface()` instead.
public struct SurfaceFinishModifier: ViewModifier {
    public init() {}

    public func apply(node: Node) {
        let shadow = node.theme.elevation.low
        node.shadow = shadow
        node.updateOverlayDraw(identity: node.theme.colors.border) { [weak node] list, origin in
            guard let node else { return }
            let inset = node.cornerRadius
            list.addRect(UIRect(x: Float(origin.x) + inset, y: Float(origin.y),
                                width: max(0, Float(node.frame.width) - inset * 2), height: 1),
                         color: node.theme.colors.border.multipliedAlpha(0.4 * node.opacity))
        }
    }
}

/// A frosted surface floating over content: translucent fill, backdrop frost,
/// hairline border, and the lift that says it is above the chrome.
///
/// One modifier because the parts only work together, and the ordering is not
/// obvious from any single piece:
///
/// - the fill has to be translucent, or it buries the frost the backdrop pass
///   just drew underneath it;
/// - `backdropBlur` is what *starts* that pass — without it there is no frost
///   at all, however translucent the fill;
/// - the border sits outside the backdrop so the rim stays crisp on top of it;
/// - the rim is painted last, over both.
///
/// Handing callers those five pieces separately is how a menu ends up looking
/// like every other card while claiming to be glass.
///
/// `blurRadius` is in points and scales with the panel, so the same value
/// frosts the same amount on any display.
public struct GlassSurfaceModifier: ViewModifier {
    public let cornerRadius: Float
    public let blurRadius: Float

    public init(cornerRadius: Float, blurRadius: Float = 12) {
        self.cornerRadius = max(0, cornerRadius)
        self.blurRadius = max(0, blurRadius)
    }

    public func apply(node: Node) {
        let colors = node.theme.colors
        node.animatableSet(\.backgroundColor, to: colors.surfaceMaterial)
        node.animatableSet(\.cornerRadius, to: cornerRadius)
        node.animatableSet(\.backdropBlur, to: blurRadius)
        node.animatableSet(\.borderColor, to: colors.border)
        node.animatableSet(\.borderWidth, to: 1)
        let floating = node.theme.elevation.floating
        node.ambientShadow = floating.ambient
        node.shadow = floating.key
    }
}

public extension View {
    func surfaceFinish() -> some View { modifier(SurfaceFinishModifier()) }

    /// Frost this surface and raise it above the chrome.
    func glassSurface(_ cornerRadius: Float, blur: Float = 12) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, blurRadius: blur))
    }

    /// The theme-driven radius, the same way `.cornerRadius(_ token:)` takes
    /// one. A surface that used `.controlRadius` before it became glass should
    /// not have to hard-code the number to keep the same shape.
    func glassSurface(_ cornerRadius: ThemeMetric, blur: Float = 12) -> some View {
        ThemeReader { theme in self.glassSurface(cornerRadius.resolve(theme), blur: blur) }
    }
}
