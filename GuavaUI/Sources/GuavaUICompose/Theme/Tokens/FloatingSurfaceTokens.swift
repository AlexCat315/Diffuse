import GuavaUIRuntime

/// Values a floating surface needs beyond the palette: the rim light that
/// turns a raised rectangle into an edge catching the light.
public extension ColorScheme {

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
    /// Derived, not authored: the palette is already at its token ceiling, and
    /// nothing here needs to differ per component.
    var edgeHighlight: Color {
        let luma = 0.2126 * surfaceFloating.r + 0.7152 * surfaceFloating.g + 0.0722 * surfaceFloating.b
        guard luma < 0.5 else {
            let sink: Float = 0.2
            return Color(r: surfaceFloating.r * (1 - sink),
                         g: surfaceFloating.g * (1 - sink),
                         b: surfaceFloating.b * (1 - sink),
                         a: 0.55)
        }
        let lift: Float = 0.38
        return Color(r: surfaceFloating.r + (1 - surfaceFloating.r) * lift,
                     g: surfaceFloating.g + (1 - surfaceFloating.g) * lift,
                     b: surfaceFloating.b + (1 - surfaceFloating.b) * lift,
                     a: 0.55)
    }
}
