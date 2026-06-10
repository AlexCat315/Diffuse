import GuavaUIRuntime

/// Default dark theme bundled with GuavaUI.
///
/// Modern-IDE palette: a dark canvas
/// (`background`) with floating panel bodies that sit *darker* than the canvas
/// (`surfaceSunken`), visible high-contrast borders, a saturated cool blue as
/// the single interactive accent, and a purple secondary accent for content
/// classification. Chrome typography runs at 11–12px.
public enum DefaultDarkTheme {
    public static let value: Theme = Theme(
        colors: ColorScheme(
            background:       Color(red: 0x1E, green: 0x1F, blue: 0x22),
            surface:          Color(red: 0x27, green: 0x29, blue: 0x2E),
            surfaceVariant:   Color(red: 0x2E, green: 0x31, blue: 0x38),
            surfaceSunken:    Color(red: 0x18, green: 0x19, blue: 0x1D),
            surfaceRaised:    Color(red: 0x2E, green: 0x30, blue: 0x36),
            surfaceFloating:  Color(red: 0x2B, green: 0x2D, blue: 0x33),
            surfaceOverlay:   Color(red: 0x23, green: 0x25, blue: 0x29),

            onBackground:     Color(red: 0xDF, green: 0xE1, blue: 0xE5),
            onSurface:        Color(red: 0xDF, green: 0xE1, blue: 0xE5),
            onSurfaceVariant: Color(red: 0xB4, green: 0xBA, blue: 0xC4),
            onSurfaceMuted:   Color(red: 0x8B, green: 0x91, blue: 0x9B),

            accent:           Color(red: 0x35, green: 0x74, blue: 0xF0),
            accentHover:      Color(red: 0x4D, green: 0x85, blue: 0xF4),
            accentPressed:    Color(red: 0x2A, green: 0x62, blue: 0xD8),
            onAccent:         Color(red: 0xFF, green: 0xFF, blue: 0xFF),
            accentMuted:      Color(red: 0x35, green: 0x74, blue: 0xF0, alpha: 0x29),
            accentSecondary:  Color(red: 0xB1, green: 0x62, blue: 0xF1),

            stateLayerHover:    Color(red: 0xFF, green: 0xFF, blue: 0xFF, alpha: 0x12),
            stateLayerPressed:  Color(red: 0xFF, green: 0xFF, blue: 0xFF, alpha: 0x1E),
            stateLayerSelected: Color(red: 0x35, green: 0x74, blue: 0xF0, alpha: 0x38),

            success:          Color(red: 0x6E, green: 0xCD, blue: 0x7E),
            warning:          Color(red: 0xEA, green: 0xC0, blue: 0x66),
            error:            Color(red: 0xF5, green: 0x6E, blue: 0x6E),
            info:             Color(red: 0x72, green: 0xB4, blue: 0xFF),

            border:           Color(red: 0x42, green: 0x46, blue: 0x4E),
            borderStrong:     Color(red: 0x50, green: 0x54, blue: 0x5D),
            divider:          Color(red: 0x42, green: 0x46, blue: 0x4E, alpha: 0x5C),
            focusRing:        Color(red: 0x35, green: 0x74, blue: 0xF0, alpha: 0xAA),
            selection:        Color(red: 0x35, green: 0x74, blue: 0xF0, alpha: 0x38),
            overlay:          Color(red: 0x00, green: 0x00, blue: 0x00, alpha: 0xB8)
        ),
        typography: Typography(
            // Chrome type ramp: titles/labels 12, body 13, captions 11.
            display:    TextStyleToken(font: .system(size: 18, weight: .semibold), lineHeight: 24),
            title:      TextStyleToken(font: .system(size: 16, weight: .semibold), lineHeight: 22),
            headline:   TextStyleToken(font: .system(size: 14, weight: .semibold), lineHeight: 19),
            body:       TextStyleToken(font: .system(size: 13, weight: .regular),  lineHeight: 18),
            bodyStrong: TextStyleToken(font: .system(size: 13, weight: .semibold), lineHeight: 18),
            caption:    TextStyleToken(font: .system(size: 11, weight: .regular),  lineHeight: 15),
            label:      TextStyleToken(font: .system(size: 12, weight: .medium),   lineHeight: 16),
            mono:       TextStyleToken(font: .system(size: 12, weight: .regular),  lineHeight: 16)
        ),
        spacing:   SpacingScale(xs: 4, sm: 6, md: 8, lg: 12, xl: 16, xxl: 24),
        // Radii: rows 5, controls 7, grouped chrome 10, panels 12.
        radius:    RadiusScale(none: 0, sm: 5, md: 7, lg: 10, xl: 12, pill: 9999),
        elevation: ElevationScale(
            none:   .none,
            low:    Shadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x50), offsetX: 0, offsetY: 1, blur: 2),
            medium: Shadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x72), offsetX: 0, offsetY: 4, blur: 12),
            high:   Shadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x96), offsetX: 0, offsetY: 12, blur: 32)
        ),
        motion: MotionScale(
            fast:           .milliseconds(80),
            standard:       .milliseconds(180),
            slow:           .milliseconds(320),
            emphasized:     .emphasized,
            standardEasing: .standard
        )
    )
}

public extension Theme {
    /// Project-wide dark theme. Value-stable across calls; safe to compare
    /// for identity within a frame.
    static let defaultDark: Theme = DefaultDarkTheme.value
}
