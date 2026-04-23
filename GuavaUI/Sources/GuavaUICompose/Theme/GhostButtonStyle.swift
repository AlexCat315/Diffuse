import GuavaUIRuntime

/// Background-less button. At rest only the label is drawn; hover/press
/// fade in a state-layer overlay. Used for tertiary actions and toolbar
/// items. Focus ring still appears on keyboard focus.
public struct GhostButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let clear = Color(r: 0, g: 0, b: 0, a: 0)
        let bg: Color = {
            if !configuration.isEnabled { return clear }
            if configuration.isPressed  { return theme.colors.stateLayerPressed }
            if configuration.isHovered  { return theme.colors.stateLayerHover }
            return clear
        }()
        let border: Color = configuration.isFocused ? theme.colors.focusRing : clear
        let borderWidth: Float = configuration.isFocused ? 2 : 0

        return Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
                .font(SemanticFontRef.bodyStrong)
                .foregroundColor(SemanticColorRef.onSurface)
        }
            .frame(height: 32)
            .padding(horizontal: theme.spacing.md, vertical: 0)
            .background(bg)
            .cornerRadius(theme.radius.md)
            .border(border, width: borderWidth)
            .opacity(configuration.isEnabled ? 1 : 0.55)
            .animation(.buttonInteraction, value: configuration.interactionKey)
    }
}


