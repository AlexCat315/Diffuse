import GuavaUIRuntime

/// Tonal / surface-variant button. Lower visual weight than primary.
/// Reads from the theme's state-layer ramp for hover/press so palette
/// changes don't require recomputing `lighter`/`darker` mixes here.
public struct SecondaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let bg: Color = {
            if !configuration.isEnabled { return theme.colors.surfaceSunken }
            // Compose state layer over the resting surfaceVariant fill. The
            // overlay is translucent so a slightly lighter / darker token
            // reads as a real surface change without needing a separate
            // pre-composited token per state.
            let base = theme.colors.surfaceVariant
            if configuration.isPressed { return base.composited(over: theme.colors.stateLayerPressed) }
            if configuration.isHovered { return base.composited(over: theme.colors.stateLayerHover) }
            return base
        }()
        let border: Color = configuration.isFocused
            ? theme.colors.focusRing
            : theme.colors.border
        let borderWidth: Float = configuration.isFocused ? 2 : 1

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
            .animation(.semantic(.fast, in: theme), value: configuration.interactionKey)
    }
}


