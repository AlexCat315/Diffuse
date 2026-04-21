import GuavaUIRuntime

/// Semantic color slots. Slot names describe the role, not a specific hue,
/// so dark/light themes can swap concrete colors without changing call sites.
///
/// Slot taxonomy (loosely following Material 3 + macOS Sonoma):
///
/// - **Surfaces** (`background` / `surface` / `surfaceVariant` / `surfaceSunken`)
///   describe filled regions, ordered from “behind everything” to
///   “pressed-in input field”.
/// - **On-surfaces** (`onBackground` / `onSurface` / `onSurfaceVariant`
///   / `onSurfaceMuted`) are foreground content tones with descending
///   contrast against their matching surface.
/// - **Accent** (`accent` / `onAccent` / `accentMuted`) is the brand action
///   color and its complementary content / tinted-fill tones.
/// - **Status** (`success` / `warning` / `error` / `info`) carry semantic
///   intent; do not hard-code substitutes for these.
/// - **Structure** (`border` / `borderStrong` / `divider` / `focusRing`
///   / `selection` / `overlay`) describes lines, focus indication, and
///   modal scrims.
public struct ColorScheme: Sendable {
    public var background: Color
    public var surface: Color
    public var surfaceVariant: Color
    public var surfaceSunken: Color

    public var onBackground: Color
    public var onSurface: Color
    public var onSurfaceVariant: Color
    public var onSurfaceMuted: Color

    public var accent: Color
    public var onAccent: Color
    public var accentMuted: Color

    public var success: Color
    public var warning: Color
    public var error: Color
    public var info: Color

    public var border: Color
    public var borderStrong: Color
    public var divider: Color
    public var focusRing: Color
    public var selection: Color
    public var overlay: Color

    public init(background: Color,
                surface: Color,
                surfaceVariant: Color,
                surfaceSunken: Color,
                onBackground: Color,
                onSurface: Color,
                onSurfaceVariant: Color,
                onSurfaceMuted: Color,
                accent: Color,
                onAccent: Color,
                accentMuted: Color,
                success: Color,
                warning: Color,
                error: Color,
                info: Color,
                border: Color,
                borderStrong: Color,
                divider: Color,
                focusRing: Color,
                selection: Color,
                overlay: Color) {
        self.background = background
        self.surface = surface
        self.surfaceVariant = surfaceVariant
        self.surfaceSunken = surfaceSunken
        self.onBackground = onBackground
        self.onSurface = onSurface
        self.onSurfaceVariant = onSurfaceVariant
        self.onSurfaceMuted = onSurfaceMuted
        self.accent = accent
        self.onAccent = onAccent
        self.accentMuted = accentMuted
        self.success = success
        self.warning = warning
        self.error = error
        self.info = info
        self.border = border
        self.borderStrong = borderStrong
        self.divider = divider
        self.focusRing = focusRing
        self.selection = selection
        self.overlay = overlay
    }
}
