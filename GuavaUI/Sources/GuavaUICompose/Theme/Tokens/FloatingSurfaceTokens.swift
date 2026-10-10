import GuavaUIRuntime

/// Values a floating surface needs beyond the palette: the rim light that
/// turns a raised rectangle into an edge catching the light.
public extension ColorScheme {

    /// Rim light for the top edge of a floating surface: the floating surface
    /// itself pushed towards white and laid down thin.
    ///
    /// Derived, not authored — the palette is already at its token ceiling, and
    /// nothing here needs to differ per component. Pushing the *floating*
    /// surface (not `surface`) towards white keeps the rim in the same family
    /// as the panel it sits on: a dark menu gets a visible edge, and a panel
    /// that is already white has nothing left to lift, so its depth comes from
    /// the shadow alone — which is how light themes read anyway.
    var edgeHighlight: Color {
        let lift: Float = 0.22
        return Color(r: surfaceFloating.r + (1 - surfaceFloating.r) * lift,
                     g: surfaceFloating.g + (1 - surfaceFloating.g) * lift,
                     b: surfaceFloating.b + (1 - surfaceFloating.b) * lift,
                     a: 0.55)
    }
}
