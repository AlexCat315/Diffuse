import GuavaUIRuntime

/// Semantic color slots. Slot names describe the role, not a specific hue,
/// so dark/light themes can swap concrete colors without changing call sites.
///
/// Slot taxonomy:
///
/// - **Surfaces** form a 5-layer elevation system. Pick the layer that
///   matches the visual hierarchy of the surface you are painting:
///     - `background`       — Layer 0, the window backdrop.
///     - `surface`          — Layer 1, panels, sidebars, tab strips.
///     - `surfaceVariant`   — Layer 1.5, inset wells inside Layer 1
///                            (text fields, badges, well backgrounds).
///     - `surfaceSunken`    — Layer 0.5, recessed grooves below Layer 1
///                            (disabled-field background, pressed-in tracks).
///     - `surfaceRaised`    — Layer 2, cards / list rows lifted above Layer 1.
///     - `surfaceFloating`  — Layer 3, popovers, dropdowns, context menus.
///     - `surfaceOverlay`   — Layer 4, modal dialogs / sheet panels.
/// - **On-surfaces** are foreground tones with descending contrast against
///   their matching surface (`onBackground` / `onSurface` /
///   `onSurfaceVariant` / `onSurfaceMuted`).
/// - **Accent** carries the brand action colour as a 4-step ramp:
///   `accentMuted` → `accent` → `accentHover` → `accentPressed`. Built-in
///   styles read these directly so palette swaps don't require recomputing
///   `lighter()`/`darker()` mixes per call site.
/// - **State layers** are translucent overlays painted on top of any surface
///   to express interaction state. Composing `stateLayerHover` over
///   `surface` gives the canonical hover look without committing the
///   underlying surface to a different fill colour.
/// - **Status** (`success` / `warning` / `error` / `info`) carry semantic
///   intent — never substitute hard-coded equivalents.
/// - **Structure** (`border` / `borderStrong` / `divider` / `focusRing`
///   / `selection` / `overlay`) describes lines, focus indication, and
///   modal scrims.
public struct ColorScheme: Sendable {
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

    // MARK: Accent ramp (rest → hover → pressed)
    public var accent: Color
    public var accentHover: Color
    public var accentPressed: Color
    public var onAccent: Color
    public var accentMuted: Color

    // MARK: State layers (translucent overlays)
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

    public init(background: Color,
                surface: Color,
                surfaceVariant: Color,
                surfaceSunken: Color,
                surfaceRaised: Color,
                surfaceFloating: Color,
                surfaceOverlay: Color,
                onBackground: Color,
                onSurface: Color,
                onSurfaceVariant: Color,
                onSurfaceMuted: Color,
                accent: Color,
                accentHover: Color,
                accentPressed: Color,
                onAccent: Color,
                accentMuted: Color,
                stateLayerHover: Color,
                stateLayerPressed: Color,
                stateLayerSelected: Color,
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
}

