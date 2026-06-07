// Theme tokens and environment. A thin colour-palette system that views query
// at draw time; the host injects a theme into the UIContext or a parent node so
// children resolve colours consistently without explicit parameters.
//
// Unlike the legacy process-global theme, GuavaKit's theme is per-context (or
// even per-subtree), matching the scoped-ownership rule.

// MARK: - Colour tokens

/// Semantic colour palette for a UI theme.
public struct ColorTokens: Equatable, Sendable {
    public var background: Color
    public var surface: Color
    public var onSurface: Color
    public var primary: Color
    public var onPrimary: Color
    public var muted: Color
    public var divider: Color
    public var error: Color

    public init(
        background: Color = Color(r: 0.08, g: 0.08, b: 0.10),
        surface: Color    = Color(r: 0.12, g: 0.12, b: 0.16),
        onSurface: Color  = Color(r: 0.90, g: 0.90, b: 0.92),
        primary: Color    = Color(r: 0.25, g: 0.55, b: 0.95),
        onPrimary: Color  = Color(r: 1, g: 1, b: 1),
        muted: Color      = Color(r: 0.45, g: 0.45, b: 0.50),
        divider: Color    = Color(r: 0.18, g: 0.18, b: 0.22),
        error: Color      = Color(r: 0.90, g: 0.25, b: 0.25)
    ) {
        self.background = background
        self.surface = surface
        self.onSurface = onSurface
        self.primary = primary
        self.onPrimary = onPrimary
        self.muted = muted
        self.divider = divider
        self.error = error
    }

    /// Light-mode variant.
    public static let light = ColorTokens(
        background: Color(r: 0.96, g: 0.96, b: 0.97),
        surface:    Color(r: 1, g: 1, b: 1),
        onSurface:  Color(r: 0.1, g: 0.1, b: 0.12),
        primary:    Color(r: 0.2, g: 0.5, b: 0.9),
        onPrimary:  Color(r: 1, g: 1, b: 1),
        muted:      Color(r: 0.55, g: 0.55, b: 0.58),
        divider:    Color(r: 0.88, g: 0.88, b: 0.90),
        error:      Color(r: 0.85, g: 0.2, b: 0.2)
    )
}

// MARK: - Theme

/// A complete UI theme. Extensible with font sizes, spacing, etc.
public struct Theme: Equatable, Sendable {
    public var colors: ColorTokens
    public var fontSize: Float
    public var smallFontSize: Float

    public init(
        colors: ColorTokens = ColorTokens(),
        fontSize: Float = 14,
        smallFontSize: Float = 11
    ) {
        self.colors = colors
        self.fontSize = fontSize
        self.smallFontSize = smallFontSize
    }

    public static let dark = Theme()
    public static let light = Theme(colors: .light)
}
