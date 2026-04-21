import GuavaUIRuntime

/// Tonal / surface-variant button. Lower visual weight than primary; suitable
/// for the second-priority action in a button group.
public struct SecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let bg: Color = {
            if !configuration.isEnabled { return theme.colors.surfaceSunken }
            if configuration.isPressed  { return theme.colors.surfaceVariant.darker(0.05) }
            if configuration.isHovered  { return theme.colors.surfaceVariant.lighter(0.05) }
            return theme.colors.surfaceVariant
        }()

        return AnyView(configuration.label)
            .font(SemanticFontRef.bodyStrong)
            .foregroundColor(SemanticColorRef.onSurface)
            .padding(horizontal: theme.spacing.lg, vertical: theme.spacing.sm)
            .background(bg)
            .cornerRadius(theme.radius.md)
            .opacity(configuration.isEnabled ? 1 : 0.55)
    }
}
