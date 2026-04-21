import GuavaUIRuntime

/// Default dark theme bundled with GuavaUI. Tuned against macOS Sonoma /
/// VS Code Dark+ / Material 3 dark surfaces so unmodified `swift run
/// GuavaUIDemo` already lands in the expected visual neighborhood.
///
/// Concrete numbers may be tweaked during Phase 7.5 implementation; the slot
/// taxonomy and the typography / spacing / radius / motion token values are
/// the load-bearing contracts and must not change without updating
/// `docs/guava-ui-phase7.5-design.md`.
public enum DefaultDarkTheme {
    public static let value: Theme = Theme(
        colors: ColorScheme(
            background:       Color(red: 0x14, green: 0x16, blue: 0x1B),
            surface:          Color(red: 0x1C, green: 0x1F, blue: 0x26),
            surfaceVariant:   Color(red: 0x24, green: 0x28, blue: 0x30),
            surfaceSunken:    Color(red: 0x10, green: 0x12, blue: 0x16),

            onBackground:     Color(red: 0xEC, green: 0xEE, blue: 0xF2),
            onSurface:        Color(red: 0xE6, green: 0xE9, blue: 0xEF),
            onSurfaceVariant: Color(red: 0xAE, green: 0xB4, blue: 0xC0),
            onSurfaceMuted:   Color(red: 0x6E, green: 0x76, blue: 0x84),

            accent:           Color(red: 0x4C, green: 0x8B, blue: 0xF5),
            onAccent:         Color(red: 0xFF, green: 0xFF, blue: 0xFF),
            accentMuted:      Color(red: 0x4C, green: 0x8B, blue: 0xF5, alpha: 0x33),

            success:          Color(red: 0x4A, green: 0xC2, blue: 0x6B),
            warning:          Color(red: 0xE5, green: 0xA5, blue: 0x3F),
            error:            Color(red: 0xE5, green: 0x55, blue: 0x4D),
            info:             Color(red: 0x5E, green: 0xA8, blue: 0xE6),

            border:           Color(red: 0x2E, green: 0x33, blue: 0x3D),
            borderStrong:     Color(red: 0x40, green: 0x46, blue: 0x52),
            divider:          Color(red: 0x24, green: 0x28, blue: 0x30),
            focusRing:        Color(red: 0x4C, green: 0x8B, blue: 0xF5, alpha: 0x99),
            selection:        Color(red: 0x2E, green: 0x4F, blue: 0x8A),
            overlay:          Color(red: 0x00, green: 0x00, blue: 0x00, alpha: 0x99)
        ),
        typography: Typography(
            display:    TextStyleToken(font: .system(size: 32, weight: .bold),     lineHeight: 38),
            title:      TextStyleToken(font: .system(size: 24, weight: .bold),     lineHeight: 30),
            headline:   TextStyleToken(font: .system(size: 18, weight: .semibold), lineHeight: 24),
            body:       TextStyleToken(font: .system(size: 14, weight: .regular),  lineHeight: 20),
            bodyStrong: TextStyleToken(font: .system(size: 14, weight: .semibold), lineHeight: 20),
            caption:    TextStyleToken(font: .system(size: 12, weight: .regular),  lineHeight: 16),
            label:      TextStyleToken(font: .system(size: 11, weight: .medium),   lineHeight: 14),
            mono:       TextStyleToken(font: .system(size: 13, weight: .regular),  lineHeight: 18)
        ),
        spacing:   SpacingScale(xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32),
        radius:    RadiusScale(none: 0, sm: 4, md: 8, lg: 12, xl: 16, pill: 9999),
        elevation: ElevationScale(
            none:   .none,
            low:    Shadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x40), offsetX: 0, offsetY: 1, blur: 2),
            medium: Shadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x55), offsetX: 0, offsetY: 4, blur: 12),
            high:   Shadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x66), offsetX: 0, offsetY: 8, blur: 24)
        ),
        motion: MotionScale(
            fast:           .milliseconds(100),
            standard:       .milliseconds(200),
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
