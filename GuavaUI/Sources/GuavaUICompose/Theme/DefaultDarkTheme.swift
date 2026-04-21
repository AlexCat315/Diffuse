import GuavaUIRuntime

/// Default dark theme bundled with GuavaUI.
///
/// Palette anchored on **Indigo 500 (`#6366F1`)** as the brand accent over a
/// **Zinc/Slate** neutral surface ramp — same family as Linear, Vercel,
/// Radix `slate` × `indigo`. The 5-layer surface ramp goes Zinc 950 →
/// Zinc 900 → Zinc 850 → Zinc 800 → Zinc 750 so cards / popovers / modals
/// each step exactly one perceptual notch above the layer underneath.
///
/// Concrete numbers may be tweaked but the slot taxonomy is the load-bearing
/// contract. Update `docs/guava-ui-design-system.md` whenever a slot is
/// renamed or its semantics change.
public enum DefaultDarkTheme {
    public static let value: Theme = Theme(
        colors: ColorScheme(
            // 5-layer surface ramp (background → overlay).
            background:       Color(red: 0x09, green: 0x09, blue: 0x0B), // zinc 950
            surface:          Color(red: 0x12, green: 0x12, blue: 0x16), // zinc 900
            surfaceVariant:   Color(red: 0x1B, green: 0x1B, blue: 0x20), // zinc 850
            surfaceSunken:    Color(red: 0x06, green: 0x06, blue: 0x08), // recessed
            surfaceRaised:    Color(red: 0x22, green: 0x22, blue: 0x28), // zinc 800
            surfaceFloating:  Color(red: 0x2A, green: 0x2A, blue: 0x32), // zinc 750
            surfaceOverlay:   Color(red: 0x32, green: 0x32, blue: 0x3C), // zinc 700

            // On-surface foregrounds.
            onBackground:     Color(red: 0xFA, green: 0xFA, blue: 0xFA), // zinc 50
            onSurface:        Color(red: 0xE4, green: 0xE4, blue: 0xE7), // zinc 200
            onSurfaceVariant: Color(red: 0xA1, green: 0xA1, blue: 0xAA), // zinc 400
            onSurfaceMuted:   Color(red: 0x71, green: 0x71, blue: 0x7A), // zinc 500

            // Accent ramp — Indigo 600 → 500 → 400.
            accent:           Color(red: 0x63, green: 0x66, blue: 0xF1), // indigo 500
            accentHover:      Color(red: 0x81, green: 0x8C, blue: 0xF8), // indigo 400
            accentPressed:    Color(red: 0x4F, green: 0x46, blue: 0xE5), // indigo 600
            onAccent:         Color(red: 0xFF, green: 0xFF, blue: 0xFF),
            accentMuted:      Color(red: 0x63, green: 0x66, blue: 0xF1, alpha: 0x33),

            // State layers — translucent overlays composed onto any surface.
            stateLayerHover:    Color(red: 0xFF, green: 0xFF, blue: 0xFF, alpha: 0x14), // 8%
            stateLayerPressed:  Color(red: 0xFF, green: 0xFF, blue: 0xFF, alpha: 0x29), // 16%
            stateLayerSelected: Color(red: 0x63, green: 0x66, blue: 0xF1, alpha: 0x33), // 20%

            // Status — Tailwind emerald/amber/red/blue 500.
            success:          Color(red: 0x10, green: 0xB9, blue: 0x81),
            warning:          Color(red: 0xF5, green: 0x9E, blue: 0x0B),
            error:            Color(red: 0xEF, green: 0x44, blue: 0x44),
            info:             Color(red: 0x3B, green: 0x82, blue: 0xF6),

            // Structure.
            border:           Color(red: 0x27, green: 0x27, blue: 0x2A), // zinc 800
            borderStrong:     Color(red: 0x3F, green: 0x3F, blue: 0x46), // zinc 700
            divider:          Color(red: 0x1F, green: 0x1F, blue: 0x25),
            focusRing:        Color(red: 0x63, green: 0x66, blue: 0xF1, alpha: 0x99),
            selection:        Color(red: 0x63, green: 0x66, blue: 0xF1, alpha: 0x40),
            overlay:          Color(red: 0x00, green: 0x00, blue: 0x00, alpha: 0xB0)
        ),
        typography: Typography(
            display:    TextStyleToken(font: .system(size: 32, weight: .bold),     lineHeight: 38),
            title:      TextStyleToken(font: .system(size: 22, weight: .semibold), lineHeight: 28),
            headline:   TextStyleToken(font: .system(size: 16, weight: .semibold), lineHeight: 22),
            body:       TextStyleToken(font: .system(size: 13, weight: .regular),  lineHeight: 18),
            bodyStrong: TextStyleToken(font: .system(size: 13, weight: .semibold), lineHeight: 18),
            caption:    TextStyleToken(font: .system(size: 11, weight: .regular),  lineHeight: 14),
            label:      TextStyleToken(font: .system(size: 10, weight: .medium),   lineHeight: 13),
            mono:       TextStyleToken(font: .system(size: 12, weight: .regular),  lineHeight: 16)
        ),
        spacing:   SpacingScale(xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32),
        radius:    RadiusScale(none: 0, sm: 4, md: 6, lg: 10, xl: 16, pill: 9999),
        elevation: ElevationScale(
            none:   .none,
            low:    Shadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x55), offsetX: 0, offsetY: 1, blur: 2),
            medium: Shadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x77), offsetX: 0, offsetY: 4, blur: 12),
            high:   Shadow(color: Color(red: 0, green: 0, blue: 0, alpha: 0x99), offsetX: 0, offsetY: 12, blur: 32)
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

