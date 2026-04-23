import GuavaUIRuntime

/// Six-dimensional design token bundle consumed by Compose-layer styles.
///
/// `Theme` is a value type — switching themes means re-providing a new value
/// through `ThemeEnvironment` (Phase 7.5 step 4). Per-axis token containers
/// (`ColorScheme`, `Typography`, …) are also value types so a call site can
/// derive a variant via `var copy = Theme.defaultDark; copy.colors.accent = …`
/// without affecting other consumers.
public struct Theme: Sendable {
    public var colors: ColorScheme
    public var typography: Typography
    public var spacing: SpacingScale
    public var radius: RadiusScale
    public var elevation: ElevationScale
    public var motion: MotionScale
    public var inputs: InputAppearance

    public init(colors: ColorScheme,
                typography: Typography,
                spacing: SpacingScale,
                radius: RadiusScale,
                elevation: ElevationScale,
                motion: MotionScale,
                inputs: InputAppearance? = nil) {
        self.colors = colors
        self.typography = typography
        self.spacing = spacing
        self.radius = radius
        self.elevation = elevation
        self.motion = motion
        // Default the input chrome from the supplied palette so legacy Theme
        // call sites that omit `inputs:` get a sensible derived appearance
        // rather than having to reconstruct one by hand.
        self.inputs = inputs ?? InputAppearance(
            background:         colors.surfaceSunken,
            backgroundDisabled: colors.surfaceVariant,
            borderColor:        colors.border,
            borderHover:        colors.borderStrong,
            borderFocused:      colors.focusRing,
            borderError:        colors.error,
            borderDisabled:     colors.border,
            borderWidth:        1,
            focusRingWidth:     2,
            addonBackground:    colors.surfaceVariant,
            addonForeground:    colors.onSurfaceMuted,
            dividerColor:       colors.border,
            radius:             radius.sm
        )
    }
}
