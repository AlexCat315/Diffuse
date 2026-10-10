import GuavaUIRuntime

/// Four-step elevation scale matching common surface tiers in tooling UI:
/// no shadow, panel edge, floating popover, and dragged / context-menu, plus
/// the two-layer shadow every floating surface actually wants.
public struct ElevationScale: Sendable {
    public var none: SurfaceShadow
    public var low: SurfaceShadow
    public var medium: SurfaceShadow
    public var high: SurfaceShadow
    /// Menus, popovers and hover cards: a broad ambient halo under a tighter
    /// key shadow. `low`/`medium`/`high` stay single-layer because a surface
    /// that sits *in* the chrome only needs one.
    public var floating: LayeredShadow

    public init(none: SurfaceShadow, low: SurfaceShadow, medium: SurfaceShadow,
                high: SurfaceShadow, floating: LayeredShadow) {
        self.none = none
        self.low = low
        self.medium = medium
        self.high = high
        self.floating = floating
    }
}
