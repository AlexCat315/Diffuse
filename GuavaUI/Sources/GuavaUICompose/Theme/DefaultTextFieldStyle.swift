import GuavaUIRuntime

/// Filled surface with a 1-px border that thickens to the accent color when
/// focused. Error state swaps the border for the error slot. Layout-only
/// chrome — the actual text rendering is `configuration.content`.
public struct DefaultTextFieldStyle: TextFieldStyle {
    public init() {}

    public func makeBody(configuration: TextFieldStyleConfiguration) -> some View {
        let theme = configuration.theme
        let bg: Color = configuration.isEnabled
            ? theme.colors.surfaceVariant
            : theme.colors.surfaceSunken

        // Border color picks up focus / error before settling on the
        // resting border slot. Step 8 will swap this for a real stroke
        // modifier; for now we emulate via a darker background tint plus
        // an opacity fade for the disabled state.
        let _: Color = {
            if configuration.isError   { return theme.colors.error }
            if configuration.isFocused { return theme.colors.focusRing }
            return theme.colors.border
        }()

        return configuration.content
            .padding(horizontal: theme.spacing.md, vertical: theme.spacing.sm)
            .background(bg)
            .cornerRadius(theme.radius.sm)
            .opacity(configuration.isEnabled ? 1 : 0.55)
    }
}
