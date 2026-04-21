import GuavaUIRuntime

/// Filled button using the `error` color slot. Suitable for irreversible
/// actions (delete, discard). Identical layout to `PrimaryButtonStyle`; only
/// the color ramp swaps `accent` for `error`.
public struct DestructiveButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let bg: Color = {
            if !configuration.isEnabled { return theme.colors.surfaceVariant }
            if configuration.isPressed  { return theme.colors.error.darker(0.10) }
            if configuration.isHovered  { return theme.colors.error.lighter(0.06) }
            return theme.colors.error
        }()

        return AnyView(configuration.label)
            .font(SemanticFontRef.bodyStrong)
            .foregroundColor(SemanticColorRef.onAccent)
            .padding(horizontal: theme.spacing.lg, vertical: theme.spacing.sm)
            .background(bg)
            .cornerRadius(theme.radius.md)
            .opacity(configuration.isEnabled ? 1 : 0.55)
    }
}
