import GuavaUIRuntime

/// Values a floating surface needs beyond the palette: its edge.
public extension ColorScheme {
    /// The outer hairline of a floating panel. A light panel has no darker
    /// body to separate it from a light page, so its edge is a crisp neutral
    /// line rather than the palette's tinted border.
    var floatingOutline: Color {
        isLightFloating ? Color(r: 0, g: 0, b: 0, a: 0.1) : border
    }

    private var isLightFloating: Bool {
        0.2126 * surfaceFloating.r + 0.7152 * surfaceFloating.g + 0.0722 * surfaceFloating.b > 0.5
    }
}
