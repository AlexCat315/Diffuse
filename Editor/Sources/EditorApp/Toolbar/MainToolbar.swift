import EditorCore
import GuavaUICompose
import GuavaUIRuntime

extension View {
    func toggleButtonStyle(_ isActive: Bool) -> some View {
        compositionLocal(ButtonStyleEnvironment.key,
                         AnyButtonStyle(EditorViewportToolbarButtonStyle(isActive: isActive)))
    }
}

private struct EditorViewportToolbarButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let base = theme.colors.surfaceSunken
        let bg: Color = {
            if !configuration.isEnabled { return theme.colors.surfaceSunken }
            if isActive {
                let selected = base.composited(over: theme.colors.stateLayerSelected)
                if configuration.isPressed { return selected.composited(over: theme.colors.stateLayerPressed) }
                if configuration.isHovered { return selected.composited(over: theme.colors.stateLayerHover) }
                return selected
            }
            if configuration.isPressed { return base.composited(over: theme.colors.stateLayerPressed) }
            if configuration.isHovered { return base.composited(over: theme.colors.stateLayerHover) }
            return base
        }()
        let border: Color = {
            if configuration.isFocused { return theme.colors.focusRing }
            if isActive { return theme.colors.accentMuted }
            return theme.colors.border
        }()
        let borderWidth: Float = configuration.isFocused ? 2 : 1
        let foreground: SemanticColorRef = isActive ? .accent : .onSurfaceVariant

        return Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
                .font(SemanticFontRef.label)
                .foregroundColor(foreground)
        }
        .frame(height: 26, minWidth: 28)
        .padding(horizontal: 7, vertical: 0)
        .background(bg)
        .cornerRadius(3)
        .border(border, width: borderWidth)
        .opacity(configuration.isEnabled ? 1 : 0.55)
        .animation(.semantic(.snappy, in: theme), value: configuration.interactionKey)
    }
}
