import GuavaUIRuntime

/// Background-less button. Only the label is drawn at rest; hover / pressed
/// states fade in a subtle surface tint. Used for tertiary actions and
/// toolbar items.
public struct GhostButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        // `.clear` sentinel — Color stores 0/0/0/0 so the renderer skips fill.
        let clear = Color(r: 0, g: 0, b: 0, a: 0)
        let bg: Color = {
            if !configuration.isEnabled { return clear }
            if configuration.isPressed  { return theme.colors.surfaceVariant }
            if configuration.isHovered  { return theme.colors.surfaceVariant.mixed(with: theme.colors.surface, amount: 0.5) }
            return clear
        }()

        return AnyView(configuration.label)
            .font(SemanticFontRef.bodyStrong)
            .foregroundColor(SemanticColorRef.accent)
            .padding(horizontal: theme.spacing.md, vertical: theme.spacing.sm)
            .background(bg)
            .cornerRadius(theme.radius.md)
            .opacity(configuration.isEnabled ? 1 : 0.55)
            .animation(.buttonInteraction, value: configuration.interactionKey)
    }
}
