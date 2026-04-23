import GuavaUIRuntime

/// Default dark theme bundled with GuavaUI.
///
/// The baseline now targets dense tool chrome rather than a marketing-style
/// dashboard: neutral graphite surfaces, a restrained blue accent, tighter
/// typography, and smaller radii so list / dock / inspector UIs read as one
/// ordered desktop workspace.
public enum DefaultDarkTheme {
    public static let value: Theme = Theme(
        colors: ColorScheme(
            background:       Color(red: 0x13, green: 0x15, blue: 0x1A),
            surface:          Color(red: 0x1B, green: 0x1E, blue: 0x24),
            surfaceVariant:   Color(red: 0x23, green: 0x27, blue: 0x2F),
            surfaceSunken:    Color(red: 0x16, green: 0x18, blue: 0x1E),
            surfaceRaised:    Color(red: 0x2A, green: 0x2F, blue: 0x38),
            surfaceFloating:  Color(red: 0x31, green: 0x37, blue: 0x42),
            surfaceOverlay:   Color(red: 0x39, green: 0x40, blue: 0x4C),

            onBackground:     Color(red: 0xF4, green: 0xF6, blue: 0xF9),
            onSurface:        Color(red: 0xE7, green: 0xEB, blue: 0xF2),
            onSurfaceVariant: Color(red: 0xBE, green: 0xC6, blue: 0xD3),
            onSurfaceMuted:   Color(red: 0x87, green: 0x91, blue: 0xA0),

            accent:           Color(red: 0x4A, green: 0x8C, blue: 0xF7),
            accentHover:      Color(red: 0x6B, green: 0xA5, blue: 0xFF),
            accentPressed:    Color(red: 0x36, green: 0x77, blue: 0xE6),
            onAccent:         Color(red: 0xFF, green: 0xFF, blue: 0xFF),
            accentMuted:      Color(red: 0x4A, green: 0x8C, blue: 0xF7, alpha: 0x30),

            stateLayerHover:    Color(red: 0xFF, green: 0xFF, blue: 0xFF, alpha: 0x12),
            stateLayerPressed:  Color(red: 0xFF, green: 0xFF, blue: 0xFF, alpha: 0x1E),
            stateLayerSelected: Color(red: 0x4A, green: 0x8C, blue: 0xF7, alpha: 0x26),

            success:          Color(red: 0x48, green: 0xC7, blue: 0x8E),
            warning:          Color(red: 0xE0, green: 0xA9, blue: 0x4A),
            error:            Color(red: 0xE2, green: 0x6D, blue: 0x5A),
            info:             Color(red: 0x65, green: 0xAF, blue: 0xFF),

            border:           Color(red: 0x31, green: 0x36, blue: 0x40),
            borderStrong:     Color(red: 0x42, green: 0x48, blue: 0x54),
            divider:          Color(red: 0x2A, green: 0x2F, blue: 0x38),
            focusRing:        Color(red: 0x4A, green: 0x8C, blue: 0xF7, alpha: 0xAA),
            selection:        Color(red: 0x4A, green: 0x8C, blue: 0xF7, alpha: 0x3D),
            overlay:          Color(red: 0x00, green: 0x00, blue: 0x00, alpha: 0xB8)
        ),
        typography: Typography(
            // Element-style ramp: 12 / 13 / 14 / 16 / 18 / 20 px
            // line-height ratio ~1.4 (Compact for chrome, Regular-ish for body)
            display:    TextStyleToken(font: .system(size: 20, weight: .semibold), lineHeight: 28),
            title:      TextStyleToken(font: .system(size: 18, weight: .semibold), lineHeight: 25),
            headline:   TextStyleToken(font: .system(size: 16, weight: .semibold), lineHeight: 22),
            body:       TextStyleToken(font: .system(size: 14, weight: .regular),  lineHeight: 20),
            bodyStrong: TextStyleToken(font: .system(size: 14, weight: .semibold), lineHeight: 20),
            caption:    TextStyleToken(font: .system(size: 12, weight: .regular),  lineHeight: 17),
            label:      TextStyleToken(font: .system(size: 12, weight: .medium),   lineHeight: 17),
            mono:       TextStyleToken(font: .system(size: 13, weight: .regular),  lineHeight: 18)
        ),
        spacing:   SpacingScale(xs: 4, sm: 6, md: 10, lg: 14, xl: 20, xxl: 28),
        radius:    RadiusScale(none: 0, sm: 3, md: 5, lg: 8, xl: 12, pill: 9999),
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

