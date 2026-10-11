import GuavaUIRuntime

/// Default light theme. The same modern-IDE language as `DefaultDarkTheme`
/// with the floating-island relationship inverted: white panel slabs float on
/// a cool light-gray canvas. Accent stays the same cool blue so dark/light
/// share one brand hue; status colors are darkened for contrast on white.
public enum DefaultLightTheme {
    public static let value: Theme = Theme(
        colors: ColorScheme(
            background:       Color(red: 0xF2, green: 0xF3, blue: 0xF5), // canvas
            surface:          Color(red: 0xF7, green: 0xF8, blue: 0xFA), // tab strips / chips
            surfaceVariant:   Color(red: 0xEB, green: 0xEC, blue: 0xF0), // wells / badges
            surfaceSunken:    Color(red: 0xFF, green: 0xFF, blue: 0xFF), // island bodies
            surfaceRaised:    Color(red: 0xFF, green: 0xFF, blue: 0xFF),
            surfaceFloating:  Color(red: 0xFF, green: 0xFF, blue: 0xFF),
            surfaceOverlay:   Color(red: 0xFF, green: 0xFF, blue: 0xFF),

            onBackground:     Color(red: 0x1E, green: 0x1F, blue: 0x22),
            onSurface:        Color(red: 0x2B, green: 0x2D, blue: 0x30),
            onSurfaceVariant: Color(red: 0x5A, green: 0x5D, blue: 0x63),
            onSurfaceMuted:   Color(red: 0x81, green: 0x85, blue: 0x94),

            accent:           Color(red: 0x35, green: 0x74, blue: 0xF0),
            accentHover:      Color(red: 0x2A, green: 0x62, blue: 0xD8),
            accentPressed:    Color(red: 0x24, green: 0x53, blue: 0xB8),
            onAccent:         Color(red: 0xFF, green: 0xFF, blue: 0xFF),
            accentMuted:      Color(red: 0x35, green: 0x74, blue: 0xF0, alpha: 0x24),
            accentSecondary:  Color(red: 0x9B, green: 0x51, blue: 0xE0),

            stateLayerHover:    Color(red: 0x1E, green: 0x1F, blue: 0x22, alpha: 0x0F), // 6%
            stateLayerPressed:  Color(red: 0x1E, green: 0x1F, blue: 0x22, alpha: 0x1F), // 12%
            stateLayerSelected: Color(red: 0x35, green: 0x74, blue: 0xF0, alpha: 0x29), // 16%

            success:          Color(red: 0x2E, green: 0x9E, blue: 0x5B),
            warning:          Color(red: 0xB8, green: 0x86, blue: 0x0B),
            error:            Color(red: 0xD6, green: 0x45, blue: 0x41),
            info:             Color(red: 0x2E, green: 0x70, blue: 0xD6),

            border:           Color(red: 0xC9, green: 0xCD, blue: 0xD4),
            borderStrong:     Color(red: 0xB4, green: 0xBA, blue: 0xC2),
            divider:          Color(red: 0xC9, green: 0xCD, blue: 0xD4, alpha: 0x7A),
            focusRing:        Color(red: 0x35, green: 0x74, blue: 0xF0, alpha: 0xAA),
            selection:        Color(red: 0x35, green: 0x74, blue: 0xF0, alpha: 0x30),
            overlay:          Color(red: 0x00, green: 0x00, blue: 0x00, alpha: 0x55)
        ),
        typography: DefaultDarkTheme.value.typography,
        spacing:    DefaultDarkTheme.value.spacing,
        radius:     DefaultDarkTheme.value.radius,
        // Not the dark theme's elevation. A black shadow over a near-white
        // canvas has far more contrast to work with than over the dark one, so
        // the same numbers that read as lift there read as dirt here: every
        // component sat in a 24pt halo of ~15% black. Light gets roughly half
        // the alpha at roughly half the spread — enough to lift, not to smudge.
        elevation: ElevationScale(
            none:   .none,
            low:    SurfaceShadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x2E), offsetX: 0, offsetY: 1, blur: 2),
            medium: SurfaceShadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x40), offsetX: 0, offsetY: 3, blur: 8),
            high:   SurfaceShadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x54), offsetX: 0, offsetY: 8, blur: 18),
            floating: LayeredShadow(
                ambient: SurfaceShadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x26),
                                       offsetX: 0, offsetY: 2, blur: 12),
                key:     SurfaceShadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x59),
                                       offsetX: 0, offsetY: 4, blur: 5)
            )
        ),
        motion:     DefaultDarkTheme.value.motion
    )
}

public extension Theme {
    /// Project-wide light theme.
    static let defaultLight: Theme = DefaultLightTheme.value
}

