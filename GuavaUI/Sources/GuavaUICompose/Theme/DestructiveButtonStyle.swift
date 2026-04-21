import GuavaUIRuntime

/// Filled button using the `error` color slot. Used for irreversible
/// actions (delete, discard). Same chrome as `PrimaryButtonStyle` but keyed
/// off the `error` colour. State variants are produced by compositing the
/// theme's state-layer overlays so the destructive ramp tracks the rest of
/// the system without per-style colour math.
public struct DestructiveButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let err = theme.colors.error
        let bg: Color = {
            if !configuration.isEnabled { return theme.colors.surfaceVariant }
            if configuration.isPressed  { return err.composited(over: theme.colors.stateLayerPressed) }
            if configuration.isHovered  { return err.composited(over: theme.colors.stateLayerHover) }
            return err
        }()
        let borderColor: Color = configuration.isFocused
            ? theme.colors.focusRing
            : Color(r: 0, g: 0, b: 0, a: 0)
        let borderWidth: Float = configuration.isFocused ? 2 : 0

        return Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
                .font(SemanticFontRef.bodyStrong)
                .foregroundColor(SemanticColorRef.onAccent)
        }
            .frame(height: 32)
            .padding(horizontal: theme.spacing.md, vertical: 0)
            .background(bg)
            .cornerRadius(theme.radius.md)
            .border(borderColor, width: borderWidth)
            .opacity(configuration.isEnabled ? 1 : 0.55)
            .animation(.buttonInteraction, value: configuration.interactionKey)
    }
}


