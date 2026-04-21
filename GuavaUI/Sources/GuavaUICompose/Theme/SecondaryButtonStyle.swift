import GuavaUIRuntime

/// Tonal / surface-variant button. Lower visual weight than primary; suitable
/// for the second-priority action in a button group. 1px strong border gives
/// it a tactile edge against the panel background.
public struct SecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let bg: Color = {
            if !configuration.isEnabled { return theme.colors.surfaceSunken }
            if configuration.isPressed  { return theme.colors.surfaceVariant.darker(0.06) }
            if configuration.isHovered  { return theme.colors.surfaceVariant.lighter(0.05) }
            return theme.colors.surfaceVariant
        }()
        let border: Color = {
            if configuration.isFocused { return theme.colors.focusRing }
            return theme.colors.borderStrong
        }()
        let borderWidth: Float = configuration.isFocused ? 2 : 1

        return AnyView(configuration.label)
            .font(SemanticFontRef.bodyStrong)
            .foregroundColor(SemanticColorRef.onSurface)
            .padding(horizontal: theme.spacing.lg, vertical: theme.spacing.sm + 2)
            .background(bg)
            .cornerRadius(theme.radius.md)
            .border(border, width: borderWidth)
            .opacity(configuration.isEnabled ? 1 : 0.55)
            .animation(.buttonInteraction, value: configuration.interactionKey)
    }
}

