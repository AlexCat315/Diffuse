import GuavaUIRuntime

/// Filled button using the `error` color slot. Suitable for irreversible
/// actions (delete, discard). Identical chrome to `PrimaryButtonStyle` but
/// keyed off the `error` colour.
public struct DestructiveButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let err = theme.colors.error
        let bg: Color = {
            if !configuration.isEnabled { return theme.colors.surfaceVariant }
            if configuration.isPressed  { return err.darker(0.10) }
            if configuration.isHovered  { return err.lighter(0.06) }
            return err
        }()
        let border: Color = {
            if configuration.isFocused { return theme.colors.focusRing }
            if !configuration.isEnabled { return theme.colors.border }
            return err.lighter(0.18)
        }()
        let borderWidth: Float = configuration.isFocused ? 2 : 1
        let shadowAlpha: Float = (configuration.isEnabled && !configuration.isPressed) ? 0.35 : 0
        let shadowColor = Color(
            r: err.r * 0.4,
            g: err.g * 0.4,
            b: err.b * 0.4,
            a: shadowAlpha
        )

        return AnyView(configuration.label)
            .font(SemanticFontRef.bodyStrong)
            .foregroundColor(SemanticColorRef.onAccent)
            .padding(horizontal: theme.spacing.lg, vertical: theme.spacing.sm + 2)
            .background(bg)
            .cornerRadius(theme.radius.md)
            .border(border, width: borderWidth)
            .shadow(color: shadowColor, offsetY: 2, blur: 6)
            .opacity(configuration.isEnabled ? 1 : 0.55)
            .animation(.buttonInteraction, value: configuration.interactionKey)
    }
}

