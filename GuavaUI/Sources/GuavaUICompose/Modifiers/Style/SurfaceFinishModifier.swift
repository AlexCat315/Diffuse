import GuavaUIRuntime

/// A faint upper edge and a shallow shadow: material without glass or gradients.
///
/// For surfaces that sit *in* the chrome — a panel edge, a sidebar. Surfaces
/// that float above it want `floatingSurface()` instead.
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

/// A floating surface: layered shadow plus a rim light along the top edge.
///
/// The shadow is what a menu cannot do without — one layer can only be broad
/// or tight, and a floating panel needs a halo *and* a contact shadow. The rim
/// light is what keeps it from reading as a sticker: it says the light is above
/// the UI, so the edge facing up catches it.
///
/// Pair with `.backdropBlur` and a translucent fill; this modifier does not
/// frost, and the fill does not lift. `glassSurface()` is the whole thing in
/// one call when the surface should frost too.
public struct FloatingSurfaceModifier: ViewModifier {
    public init() {}

    public func apply(node: Node) {
        let floating = node.theme.elevation.floating
        node.ambientShadow = floating.ambient
        node.shadow = floating.key
        // A full point, and that is the floor. The rasteriser drops geometry
        // thinner than a pixel outright — a 0.5pt line lands exactly between
        // two sample points and disappears — so a narrower rim would not read
        // as finer, it would read as absent on any non-retina display.
        // Restraint has to come from the rim's alpha instead.
        node.highlight = SurfaceHighlight(color: node.theme.colors.edgeHighlight)
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
        node.highlight = SurfaceHighlight(color: colors.edgeHighlight)
    }
}

public extension View {
    func surfaceFinish() -> some View { modifier(SurfaceFinishModifier()) }

    /// Raise this surface above the chrome: layered shadow and a light top edge.
    func floatingSurface() -> some View { modifier(FloatingSurfaceModifier()) }

    /// Frost this surface and raise it above the chrome.
    func glassSurface(_ cornerRadius: Float, blur: Float = 12) -> some View {
        modifier(GlassSurfaceModifier(cornerRadius: cornerRadius, blurRadius: blur))
    }
}
