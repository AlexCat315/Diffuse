import GuavaUIRuntime

/// Values a floating surface needs beyond the palette: the rim light that
/// turns a raised rectangle into an edge catching the light.
public extension ColorScheme {

    /// Fill for a panel that frosts what is behind it.
    ///
    /// A *material*, not a solid: the backdrop only reaches the screen by
    /// `(1 - alpha)` of it, so a high alpha leaves the frost running at a few
    /// percent, which looks like a painted panel that happened to be
    /// translucent, not like glass.
    ///
    /// The cost of a low alpha is legibility, and only where the backdrop is
    /// bright. Over the canvas these panels actually sit on, the dark theme
    /// lands at 11.6:1 against label text and the light theme at 13.4:1 —
    /// both *better* than a higher alpha would give. Over pure white the dark
    /// panel drops to 2.3:1, so a material over bright content needs a
    /// backing of its own rather than leaning on this fill.
    var surfaceMaterial: Color {
        surfaceFloating.multipliedAlpha(0.5)
    }
}
