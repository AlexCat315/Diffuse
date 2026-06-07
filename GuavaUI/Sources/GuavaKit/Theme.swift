// Theme tokens and semantic references. A thin colour-palette system that
// views query at draw time; the host injects a theme into the UIContext so
// children resolve colours and fonts consistently without explicit parameters.
//
// Unlike the legacy process-global theme, GuavaKit's theme is per-context
// (scoped-ownership rule).

// MARK: - FontWeight

/// Standard font weight scale. Matches the GuavaUIRuntime `FontWeight` so the
/// bridge (GuavaKitHost) can map 1:1 without a translation layer.
public enum FontWeight: Equatable, Sendable {
    case regular
    case medium
    case semibold
    case bold
}

// MARK: - TextStyleToken

/// One typography slot — font size, weight, line-height, and letter spacing
/// that travel together. Components consume the whole token rather than just
/// `fontSize` so vertical rhythm stays stable across themes.
public struct TextStyleToken: Equatable, Sendable {
    public var fontSize: Float
    public var weight: FontWeight
    public var lineHeight: Float
    public var letterSpacing: Float

    public init(fontSize: Float, weight: FontWeight = .regular,
                lineHeight: Float, letterSpacing: Float = 0) {
        self.fontSize = fontSize
        self.weight = weight
        self.lineHeight = lineHeight
        self.letterSpacing = letterSpacing
    }
}

// MARK: - Typography

/// Type scale slots covering display through caption plus a monospace slot
/// for consoles and code listings. Slot names describe role, not size.
public struct Typography: Equatable, Sendable {
    public var display: TextStyleToken
    public var title: TextStyleToken
    public var headline: TextStyleToken
    public var body: TextStyleToken
    public var bodyStrong: TextStyleToken
    public var caption: TextStyleToken
    public var label: TextStyleToken
    public var mono: TextStyleToken

    public init(display: TextStyleToken,
                title: TextStyleToken,
                headline: TextStyleToken,
                body: TextStyleToken,
                bodyStrong: TextStyleToken,
                caption: TextStyleToken,
                label: TextStyleToken,
                mono: TextStyleToken) {
        self.display = display
        self.title = title
        self.headline = headline
        self.body = body
        self.bodyStrong = bodyStrong
        self.caption = caption
        self.label = label
        self.mono = mono
    }

    /// Default dark-editor scale (sizes in points, line-height 1.25×).
    public static let dark = Typography(
        display:    TextStyleToken(fontSize: 28, weight: .bold,       lineHeight: 35),
        title:      TextStyleToken(fontSize: 20, weight: .semibold,   lineHeight: 25),
        headline:   TextStyleToken(fontSize: 15, weight: .semibold,   lineHeight: 19),
        body:       TextStyleToken(fontSize: 13, weight: .regular,    lineHeight: 18),
        bodyStrong: TextStyleToken(fontSize: 13, weight: .semibold,   lineHeight: 18),
        caption:    TextStyleToken(fontSize: 11, weight: .regular,    lineHeight: 15),
        label:      TextStyleToken(fontSize: 10, weight: .medium,     lineHeight: 13),
        mono:       TextStyleToken(fontSize: 11, weight: .regular,    lineHeight: 15)
    )

    /// Light-editor scale.
    public static let light = Typography(
        display:    TextStyleToken(fontSize: 28, weight: .bold,       lineHeight: 35),
        title:      TextStyleToken(fontSize: 20, weight: .semibold,   lineHeight: 25),
        headline:   TextStyleToken(fontSize: 15, weight: .semibold,   lineHeight: 19),
        body:       TextStyleToken(fontSize: 13, weight: .regular,    lineHeight: 18),
        bodyStrong: TextStyleToken(fontSize: 13, weight: .semibold,   lineHeight: 18),
        caption:    TextStyleToken(fontSize: 11, weight: .regular,    lineHeight: 15),
        label:      TextStyleToken(fontSize: 10, weight: .medium,     lineHeight: 13),
        mono:       TextStyleToken(fontSize: 11, weight: .regular,    lineHeight: 15)
    )
}

// MARK: - ColorScheme

/// Semantic color slots. Slot names describe the role, not a specific hue,
/// so dark/light themes can swap concrete colors without changing call sites.
///
/// Slot taxonomy:
///
/// - **Surfaces** form a 5-layer elevation system:
///     - `background`       — Layer 0, the window backdrop.
///     - `surface`          — Layer 1, panels, sidebars, tab strips.
///     - `surfaceVariant`   — Layer 1.5, inset wells (text fields, badges).
///     - `surfaceSunken`    — Layer 0.5, recessed grooves (disabled fields).
///     - `surfaceRaised`    — Layer 2, cards / list rows lifted above Layer 1.
///     - `surfaceFloating`  — Layer 3, popovers, dropdowns, context menus.
///     - `surfaceOverlay`   — Layer 4, modal dialogs / sheet panels.
/// - **On-surfaces** are foreground tones with descending contrast:
///   `onBackground` / `onSurface` / `onSurfaceVariant` / `onSurfaceMuted`.
/// - **Accent** carries the brand action colour ramp:
///   `accentMuted` → `accent` → `accentHover` → `accentPressed`.
/// - **State layers** are translucent overlays for interaction states.
/// - **Status** (`success` / `warning` / `error` / `info`) carry semantic intent.
/// - **Structure** (`border` / `borderStrong` / `divider` / `focusRing`
///   / `selection` / `overlay`) describes lines, focus indication, and scrims.
public struct ColorScheme: Equatable, Sendable {
    // MARK: Surfaces (Layer system)
    public var background: Color
    public var surface: Color
    public var surfaceVariant: Color
    public var surfaceSunken: Color
    public var surfaceRaised: Color
    public var surfaceFloating: Color
    public var surfaceOverlay: Color

    // MARK: On-surfaces
    public var onBackground: Color
    public var onSurface: Color
    public var onSurfaceVariant: Color
    public var onSurfaceMuted: Color

    // MARK: Accent ramp
    public var accent: Color
    public var accentHover: Color
    public var accentPressed: Color
    public var onAccent: Color
    public var accentMuted: Color

    // MARK: State layers
    public var stateLayerHover: Color
    public var stateLayerPressed: Color
    public var stateLayerSelected: Color

    // MARK: Status
    public var success: Color
    public var warning: Color
    public var error: Color
    public var info: Color

    // MARK: Structure
    public var border: Color
    public var borderStrong: Color
    public var divider: Color
    public var focusRing: Color
    public var selection: Color
    public var overlay: Color

    public init(
        background: Color, surface: Color, surfaceVariant: Color,
        surfaceSunken: Color, surfaceRaised: Color,
        surfaceFloating: Color, surfaceOverlay: Color,
        onBackground: Color, onSurface: Color,
        onSurfaceVariant: Color, onSurfaceMuted: Color,
        accent: Color, accentHover: Color, accentPressed: Color,
        onAccent: Color, accentMuted: Color,
        stateLayerHover: Color, stateLayerPressed: Color,
        stateLayerSelected: Color,
        success: Color, warning: Color, error: Color, info: Color,
        border: Color, borderStrong: Color,
        divider: Color, focusRing: Color,
        selection: Color, overlay: Color
    ) {
        self.background = background
        self.surface = surface
        self.surfaceVariant = surfaceVariant
        self.surfaceSunken = surfaceSunken
        self.surfaceRaised = surfaceRaised
        self.surfaceFloating = surfaceFloating
        self.surfaceOverlay = surfaceOverlay
        self.onBackground = onBackground
        self.onSurface = onSurface
        self.onSurfaceVariant = onSurfaceVariant
        self.onSurfaceMuted = onSurfaceMuted
        self.accent = accent
        self.accentHover = accentHover
        self.accentPressed = accentPressed
        self.onAccent = onAccent
        self.accentMuted = accentMuted
        self.stateLayerHover = stateLayerHover
        self.stateLayerPressed = stateLayerPressed
        self.stateLayerSelected = stateLayerSelected
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

    /// Dark editor palette.
    public static let dark = ColorScheme(
        background:        Color(r: 0.08, g: 0.08, b: 0.10),
        surface:           Color(r: 0.12, g: 0.12, b: 0.16),
        surfaceVariant:    Color(r: 0.16, g: 0.16, b: 0.20),
        surfaceSunken:     Color(r: 0.06, g: 0.06, b: 0.08),
        surfaceRaised:     Color(r: 0.18, g: 0.18, b: 0.22),
        surfaceFloating:   Color(r: 0.22, g: 0.22, b: 0.26),
        surfaceOverlay:    Color(r: 0.14, g: 0.14, b: 0.18),
        onBackground:      Color(r: 0.90, g: 0.90, b: 0.92),
        onSurface:         Color(r: 0.88, g: 0.88, b: 0.90),
        onSurfaceVariant:  Color(r: 0.60, g: 0.60, b: 0.65),
        onSurfaceMuted:    Color(r: 0.40, g: 0.40, b: 0.45),
        accent:            Color(r: 0.25, g: 0.55, b: 0.95),
        accentHover:       Color(r: 0.35, g: 0.62, b: 0.98),
        accentPressed:     Color(r: 0.18, g: 0.45, b: 0.85),
        onAccent:          Color(r: 1, g: 1, b: 1),
        accentMuted:       Color(r: 0.15, g: 0.35, b: 0.60),
        stateLayerHover:   Color(r: 1, g: 1, b: 1, a: 0.06),
        stateLayerPressed: Color(r: 1, g: 1, b: 1, a: 0.10),
        stateLayerSelected:Color(r: 0.25, g: 0.55, b: 0.95, a: 0.15),
        success:           Color(r: 0.20, g: 0.80, b: 0.40),
        warning:           Color(r: 0.95, g: 0.70, b: 0.20),
        error:             Color(r: 0.90, g: 0.25, b: 0.25),
        info:              Color(r: 0.30, g: 0.60, b: 0.90),
        border:            Color(r: 0.20, g: 0.20, b: 0.25),
        borderStrong:      Color(r: 0.30, g: 0.30, b: 0.35),
        divider:           Color(r: 0.18, g: 0.18, b: 0.22),
        focusRing:         Color(r: 0.25, g: 0.55, b: 0.95, a: 0.60),
        selection:         Color(r: 0.25, g: 0.55, b: 0.95, a: 0.25),
        overlay:           Color(r: 0, g: 0, b: 0, a: 0.50)
    )

    /// Light editor palette.
    public static let light = ColorScheme(
        background:        Color(r: 0.96, g: 0.96, b: 0.97),
        surface:           Color(r: 1, g: 1, b: 1),
        surfaceVariant:    Color(r: 0.94, g: 0.94, b: 0.95),
        surfaceSunken:     Color(r: 0.88, g: 0.88, b: 0.90),
        surfaceRaised:     Color(r: 0.98, g: 0.98, b: 0.99),
        surfaceFloating:   Color(r: 1, g: 1, b: 1),
        surfaceOverlay:    Color(r: 0.96, g: 0.96, b: 0.97),
        onBackground:      Color(r: 0.10, g: 0.10, b: 0.12),
        onSurface:         Color(r: 0.12, g: 0.12, b: 0.14),
        onSurfaceVariant:  Color(r: 0.35, g: 0.35, b: 0.40),
        onSurfaceMuted:    Color(r: 0.55, g: 0.55, b: 0.58),
        accent:            Color(r: 0.20, g: 0.50, b: 0.90),
        accentHover:       Color(r: 0.25, g: 0.55, b: 0.95),
        accentPressed:     Color(r: 0.15, g: 0.40, b: 0.80),
        onAccent:          Color(r: 1, g: 1, b: 1),
        accentMuted:       Color(r: 0.30, g: 0.55, b: 0.85),
        stateLayerHover:   Color(r: 0, g: 0, b: 0, a: 0.04),
        stateLayerPressed: Color(r: 0, g: 0, b: 0, a: 0.08),
        stateLayerSelected:Color(r: 0.20, g: 0.50, b: 0.90, a: 0.12),
        success:           Color(r: 0.20, g: 0.75, b: 0.35),
        warning:           Color(r: 0.90, g: 0.60, b: 0.15),
        error:             Color(r: 0.85, g: 0.20, b: 0.20),
        info:              Color(r: 0.25, g: 0.55, b: 0.85),
        border:            Color(r: 0.82, g: 0.82, b: 0.84),
        borderStrong:      Color(r: 0.65, g: 0.65, b: 0.68),
        divider:           Color(r: 0.88, g: 0.88, b: 0.90),
        focusRing:         Color(r: 0.20, g: 0.50, b: 0.90, a: 0.40),
        selection:         Color(r: 0.20, g: 0.50, b: 0.90, a: 0.15),
        overlay:           Color(r: 0, g: 0, b: 0, a: 0.30)
    )
}

// MARK: - SpacingScale

/// Baseline spacing scale in points. Eight steps (xs → xxl).
public struct SpacingScale: Equatable, Sendable {
    public var xs: Float, sm: Float, md: Float, lg: Float
    public var xl: Float, xxl: Float
    public var padding: Float   // default panel body padding

    public init(xs: Float, sm: Float, md: Float, lg: Float,
                xl: Float, xxl: Float, padding: Float) {
        self.xs = xs; self.sm = sm; self.md = md; self.lg = lg
        self.xl = xl; self.xxl = xxl; self.padding = padding
    }

    public static let standard = SpacingScale(
        xs: 2, sm: 4, md: 8, lg: 12, xl: 16, xxl: 24, padding: 10
    )
}

// MARK: - RadiusScale

/// Corner radius scale.
public struct RadiusScale: Equatable, Sendable {
    public var sm: Float, md: Float, lg: Float, full: Float
    public init(sm: Float, md: Float, lg: Float, full: Float = 999) {
        self.sm = sm; self.md = md; self.lg = lg; self.full = full
    }
    public static let standard = RadiusScale(sm: 3, md: 6, lg: 10)
}

// MARK: - Theme

/// A complete UI theme. Per-context, never process-global.
public struct Theme: Equatable, Sendable {
    public var colors: ColorScheme
    public var typography: Typography
    public var spacing: SpacingScale
    public var radius: RadiusScale

    public init(colors: ColorScheme = .dark,
                typography: Typography = .dark,
                spacing: SpacingScale = .standard,
                radius: RadiusScale = .standard) {
        self.colors = colors
        self.typography = typography
        self.spacing = spacing
        self.radius = radius
    }

    public static let dark = Theme()
    public static let light = Theme(colors: .light, typography: .light)
}

// MARK: - SemanticColorRef

/// Late-bound color reference resolved against the active `ColorScheme`.
///
/// `Color` is a value type and intentionally does not carry a theme reference,
/// so semantic colors are expressed as `SemanticColorRef` and resolved at
/// modifier-apply time via the node's context. This keeps `Color` cheap to
/// copy and the resolution cost paid once per node per recompose.
public struct SemanticColorRef: Sendable {
    let resolve: @Sendable (ColorScheme) -> Color
    public init(_ resolve: @escaping @Sendable (ColorScheme) -> Color) {
        self.resolve = resolve
    }
}

public extension SemanticColorRef {
    static let background       = SemanticColorRef { $0.background }
    static let surface          = SemanticColorRef { $0.surface }
    static let surfaceVariant   = SemanticColorRef { $0.surfaceVariant }
    static let surfaceSunken    = SemanticColorRef { $0.surfaceSunken }
    static let surfaceRaised    = SemanticColorRef { $0.surfaceRaised }
    static let surfaceFloating  = SemanticColorRef { $0.surfaceFloating }
    static let surfaceOverlay   = SemanticColorRef { $0.surfaceOverlay }

    static let onBackground     = SemanticColorRef { $0.onBackground }
    static let onSurface        = SemanticColorRef { $0.onSurface }
    static let onSurfaceVariant = SemanticColorRef { $0.onSurfaceVariant }
    static let onSurfaceMuted   = SemanticColorRef { $0.onSurfaceMuted }

    static let accent           = SemanticColorRef { $0.accent }
    static let accentHover      = SemanticColorRef { $0.accentHover }
    static let accentPressed    = SemanticColorRef { $0.accentPressed }
    static let onAccent         = SemanticColorRef { $0.onAccent }
    static let accentMuted      = SemanticColorRef { $0.accentMuted }

    static let stateLayerHover    = SemanticColorRef { $0.stateLayerHover }
    static let stateLayerPressed  = SemanticColorRef { $0.stateLayerPressed }
    static let stateLayerSelected = SemanticColorRef { $0.stateLayerSelected }

    static let success          = SemanticColorRef { $0.success }
    static let warning          = SemanticColorRef { $0.warning }
    static let error            = SemanticColorRef { $0.error }
    static let info             = SemanticColorRef { $0.info }

    static let border           = SemanticColorRef { $0.border }
    static let borderStrong     = SemanticColorRef { $0.borderStrong }
    static let divider          = SemanticColorRef { $0.divider }
    static let focusRing        = SemanticColorRef { $0.focusRing }
    static let selection        = SemanticColorRef { $0.selection }
    static let overlay          = SemanticColorRef { $0.overlay }
}

// MARK: - SemanticFontRef

/// Late-bound text-style reference resolved against the active `Typography`.
public struct SemanticFontRef: Sendable {
    let resolve: @Sendable (Typography) -> TextStyleToken
    public init(_ resolve: @escaping @Sendable (Typography) -> TextStyleToken) {
        self.resolve = resolve
    }
}

public extension SemanticFontRef {
    static let display    = SemanticFontRef { $0.display }
    static let title      = SemanticFontRef { $0.title }
    static let headline   = SemanticFontRef { $0.headline }
    static let body       = SemanticFontRef { $0.body }
    static let bodyStrong = SemanticFontRef { $0.bodyStrong }
    static let caption    = SemanticFontRef { $0.caption }
    static let label      = SemanticFontRef { $0.label }
    static let mono       = SemanticFontRef { $0.mono }
}
