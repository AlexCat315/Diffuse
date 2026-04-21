import GuavaUIRuntime

/// Filled, accent-colored button. Default style for `Button`. State mapping:
/// disabled → `surfaceVariant`; pressed → `accent.darker(0.10)`;
/// hovered → `accent.lighter(0.06)`; otherwise → `accent`.
public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let bg: Color = {
            if !configuration.isEnabled { return theme.colors.surfaceVariant }
            if configuration.isPressed  { return theme.colors.accent.darker(0.10) }
            if configuration.isHovered  { return theme.colors.accent.lighter(0.06) }
            return theme.colors.accent
        }()
        let fg: SemanticColorRef =
            configuration.isEnabled ? .onAccent : .onSurfaceMuted

        return AnyView(configuration.label)
            .font(SemanticFontRef.bodyStrong)
            .foregroundColor(fg)
            .padding(horizontal: theme.spacing.lg, vertical: theme.spacing.sm)
            .background(bg)
            .cornerRadius(theme.radius.md)
            .opacity(configuration.isEnabled ? 1 : 0.55)
    }
}
