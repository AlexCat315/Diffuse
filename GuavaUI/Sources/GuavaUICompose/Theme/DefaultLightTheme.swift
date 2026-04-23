import GuavaUIRuntime

/// Default light theme. Mirrors `DefaultDarkTheme`'s slot taxonomy with the
/// surface ramp inverted onto **Zinc 50 → Zinc 200** and the same Indigo
/// accent ramp. Numbers may evolve, but the slot contracts and token
/// shapes stay locked in step with the dark theme.
public enum DefaultLightTheme {
    public static let value: Theme = Theme(
        colors: ColorScheme(
            // 5-layer surface ramp.
            background:       Color(red: 0xFA, green: 0xFA, blue: 0xFA), // zinc 50
            surface:          Color(red: 0xFF, green: 0xFF, blue: 0xFF),
            surfaceVariant:   Color(red: 0xF4, green: 0xF4, blue: 0xF5), // zinc 100
            surfaceSunken:    Color(red: 0xE4, green: 0xE4, blue: 0xE7), // zinc 200
            surfaceRaised:    Color(red: 0xFF, green: 0xFF, blue: 0xFF),
            surfaceFloating:  Color(red: 0xFF, green: 0xFF, blue: 0xFF),
            surfaceOverlay:   Color(red: 0xFF, green: 0xFF, blue: 0xFF),

            onBackground:     Color(red: 0x09, green: 0x09, blue: 0x0B), // zinc 950
            onSurface:        Color(red: 0x18, green: 0x18, blue: 0x1B), // zinc 900
            onSurfaceVariant: Color(red: 0x52, green: 0x52, blue: 0x5B), // zinc 600
            onSurfaceMuted:   Color(red: 0xA1, green: 0xA1, blue: 0xAA), // zinc 400

            accent:           Color(red: 0x4F, green: 0x46, blue: 0xE5), // indigo 600
            accentHover:      Color(red: 0x63, green: 0x66, blue: 0xF1), // indigo 500
            accentPressed:    Color(red: 0x43, green: 0x38, blue: 0xCA), // indigo 700
            onAccent:         Color(red: 0xFF, green: 0xFF, blue: 0xFF),
            accentMuted:      Color(red: 0x4F, green: 0x46, blue: 0xE5, alpha: 0x22),

            stateLayerHover:    Color(red: 0x09, green: 0x09, blue: 0x0B, alpha: 0x0F), // 6%
            stateLayerPressed:  Color(red: 0x09, green: 0x09, blue: 0x0B, alpha: 0x1F), // 12%
            stateLayerSelected: Color(red: 0x4F, green: 0x46, blue: 0xE5, alpha: 0x29), // 16%

            success:          Color(red: 0x05, green: 0x96, blue: 0x69), // emerald 600
            warning:          Color(red: 0xD9, green: 0x77, blue: 0x06), // amber 600
            error:            Color(red: 0xDC, green: 0x26, blue: 0x26), // red 600
            info:             Color(red: 0x25, green: 0x63, blue: 0xEB), // blue 600

            border:           Color(red: 0xE4, green: 0xE4, blue: 0xE7), // zinc 200
            borderStrong:     Color(red: 0xD4, green: 0xD4, blue: 0xD8), // zinc 300
            divider:          Color(red: 0xE4, green: 0xE4, blue: 0xE7),
            focusRing:        Color(red: 0x4F, green: 0x46, blue: 0xE5, alpha: 0x99),
            selection:        Color(red: 0x4F, green: 0x46, blue: 0xE5, alpha: 0x29),
            overlay:          Color(red: 0x00, green: 0x00, blue: 0x00, alpha: 0x55)
        ),
        typography: DefaultDarkTheme.value.typography,
        spacing:    DefaultDarkTheme.value.spacing,
        radius:     DefaultDarkTheme.value.radius,
        elevation:  DefaultDarkTheme.value.elevation,
        motion:     DefaultDarkTheme.value.motion
    )
}

public extension Theme {
    /// Project-wide light theme.
    static let defaultLight: Theme = DefaultLightTheme.value
}

