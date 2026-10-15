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

    /// The rim that turns a raised rectangle into an edge catching the light.
    ///
    /// It moves *away* from the surface it sits on, and which way "away" is
    /// depends on the surface — there is no single direction that reads as an
    /// edge on both a dark panel and a white one.
    ///
    /// On a dark surface the light above catches the rim, so it lifts towards
    /// white, and it has to lift hard: a frosted panel is lightened from
    /// underneath by the backdrop pass first, and a timid rim is eaten by that.
    ///
    /// On a light surface a highlight has nowhere to go — white lifted towards
    /// white is still white, which is why a light theme used to show no rim at
    /// all. What actually reads as a pane of glass against a bright background
    /// is the edge going *down*: the same total internal reflection that makes
    /// the rim of real glass visible when it is lit from the front. So the
    /// light theme sinks instead of lifting.
    ///
    /// Both directions stay restrained. The rim is drawn just inside the
    /// panel's own 1pt border, so the two read as a single edge; push either
    /// and every popover turns into an outlined box.
    ///
    /// Derived, not authored: the palette is already at its token ceiling, and
    /// nothing here needs to differ per component.
    var edgeHighlight: Color {
        let luma = 0.2126 * surfaceFloating.r + 0.7152 * surfaceFloating.g + 0.0722 * surfaceFloating.b
        guard luma < 0.5 else {
            let sink: Float = 0.15
            return Color(r: surfaceFloating.r * (1 - sink),
                         g: surfaceFloating.g * (1 - sink),
                         b: surfaceFloating.b * (1 - sink),
                         a: 0.4)
        }
        let lift: Float = 0.3
        return Color(r: surfaceFloating.r + (1 - surfaceFloating.r) * lift,
                     g: surfaceFloating.g + (1 - surfaceFloating.g) * lift,
                     b: surfaceFloating.b + (1 - surfaceFloating.b) * lift,
                     a: 0.4)
    }
}
