import GuavaUIRuntime

/// Filled, accent-colored button. Default style for `Button`.
///
/// Visual recipe:
/// - Rest: solid `accent` fill with a 1px `accent.lighter(0.18)` highlight
///   border, plus a soft 6px tinted drop shadow.
/// - Hover: fill brightens to `accent.lighter(0.06)`.
/// - Pressed: fill darkens to `accent.darker(0.10)` and the shadow collapses
///   so the button visually settles into the surface.
/// - Disabled: surface fill at 55% opacity, no shadow.
/// - Focused: 2px `focusRing` border replaces the highlight.
public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let accent = theme.colors.accent
        let bg: Color = {
            if !configuration.isEnabled { return theme.colors.surfaceVariant }
            if configuration.isPressed  { return accent.darker(0.10) }
            if configuration.isHovered  { return accent.lighter(0.06) }
            return accent
        }()
        let fg: SemanticColorRef =
            configuration.isEnabled ? .onAccent : .onSurfaceMuted

        let border: Color = {
            if configuration.isFocused { return theme.colors.focusRing }
            if !configuration.isEnabled { return theme.colors.border }
            return accent.lighter(0.18)
        }()
        let borderWidth: Float = configuration.isFocused ? 2 : 1

        let shadowAlpha: Float = (configuration.isEnabled && !configuration.isPressed) ? 0.35 : 0
        let shadowColor = Color(
            r: accent.r * 0.4,
            g: accent.g * 0.4,
            b: accent.b * 0.4,
            a: shadowAlpha
        )

        return AnyView(configuration.label)
            .font(SemanticFontRef.bodyStrong)
            .foregroundColor(fg)
            .padding(horizontal: theme.spacing.lg, vertical: theme.spacing.sm + 2)
            .background(bg)
            .cornerRadius(theme.radius.md)
            .border(border, width: borderWidth)
            .shadow(color: shadowColor, offsetY: 2, blur: 6)
            .opacity(configuration.isEnabled ? 1 : 0.55)
            .animation(.buttonInteraction, value: configuration.interactionKey)
    }
}

