import GuavaUIRuntime

/// Default light theme. Mirrors `DefaultDarkTheme`'s slot taxonomy but
/// painted against a white background. Tuned against macOS Sonoma /
/// VS Code Light+ / Material 3 light surfaces; numbers may evolve, but the
/// slot contracts and token shapes stay locked in step with the dark theme.
public enum DefaultLightTheme {
    public static let value: Theme = Theme(
        colors: ColorScheme(
            background:       Color(red: 0xFA, green: 0xFA, blue: 0xFC),
            surface:          Color(red: 0xFF, green: 0xFF, blue: 0xFF),
            surfaceVariant:   Color(red: 0xF1, green: 0xF3, blue: 0xF7),
            surfaceSunken:    Color(red: 0xE6, green: 0xE9, blue: 0xEF),

            onBackground:     Color(red: 0x16, green: 0x1A, blue: 0x22),
            onSurface:        Color(red: 0x1F, green: 0x24, blue: 0x2D),
            onSurfaceVariant: Color(red: 0x4A, green: 0x52, blue: 0x60),
            onSurfaceMuted:   Color(red: 0x80, green: 0x88, blue: 0x96),

            accent:           Color(red: 0x2C, green: 0x6B, blue: 0xE0),
            onAccent:         Color(red: 0xFF, green: 0xFF, blue: 0xFF),
            accentMuted:      Color(red: 0x2C, green: 0x6B, blue: 0xE0, alpha: 0x22),

            success:          Color(red: 0x1F, green: 0x9D, blue: 0x55),
            warning:          Color(red: 0xC9, green: 0x82, blue: 0x12),
            error:            Color(red: 0xD0, green: 0x39, blue: 0x3A),
            info:             Color(red: 0x2E, green: 0x82, blue: 0xC4),

            border:           Color(red: 0xDC, green: 0xE0, blue: 0xE7),
            borderStrong:     Color(red: 0xBF, green: 0xC5, blue: 0xCF),
            divider:          Color(red: 0xE6, green: 0xE9, blue: 0xEF),
            focusRing:        Color(red: 0x2C, green: 0x6B, blue: 0xE0, alpha: 0x88),
            selection:        Color(red: 0xCB, green: 0xDC, blue: 0xF7),
            overlay:          Color(red: 0x16, green: 0x1A, blue: 0x22, alpha: 0x55)
        ),
        // Typography / spacing / radius / motion stay token-identical with
        // the dark theme — only the palette flips. Designers can override the
        // light theme in place for per-product tuning.
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
