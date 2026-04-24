import GuavaUIRuntime

/// Filled, accent-coloured button. Default style for `Button`.
///
/// Visual recipe (consumes the theme's accent ramp directly):
/// - Rest:    fill = `accent`,         border = transparent.
/// - Hover:   fill = `accentHover`.
/// - Pressed: fill = `accentPressed`.
/// - Disabled: fill = `surfaceVariant`, foreground = `onSurfaceMuted`.
/// - Focused: 2px `focusRing` border replaces the highlight ring.
///
/// No drop shadow at this layer — primary buttons live on top of `surface`
/// (Layer 1); they don't need to "lift" off it. Use `.shadow(...)` on the
/// owning button if a popover-style elevation is required.
public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let bg: Color = {
            if !configuration.isEnabled { return theme.colors.surfaceVariant }
            if configuration.isPressed  { return theme.colors.accentPressed }
            if configuration.isHovered  { return theme.colors.accentHover }
            return theme.colors.accent
        }()
        let fg: SemanticColorRef =
            configuration.isEnabled ? .onAccent : .onSurfaceMuted

        let borderColor: Color = configuration.isFocused
            ? theme.colors.focusRing
            : Color(r: 0, g: 0, b: 0, a: 0)
        let borderWidth: Float = configuration.isFocused ? 2 : 0

        return Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
                .font(SemanticFontRef.bodyStrong)
                .foregroundColor(fg)
        }
            .frame(height: 32)
            .padding(horizontal: theme.spacing.md, vertical: 0)
            .background(bg)
            .cornerRadius(theme.radius.md)
            .border(borderColor, width: borderWidth)
            .opacity(configuration.isEnabled ? 1 : 0.55)
            .animation(.semantic(.snappy, in: theme), value: configuration.interactionKey)
    }
}


