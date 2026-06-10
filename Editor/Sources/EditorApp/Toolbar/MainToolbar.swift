import EditorCore
import GuavaUICompose
import GuavaUIRuntime

extension View {
    func toggleButtonStyle(_ isActive: Bool) -> some View {
        compositionLocal(ButtonStyleEnvironment.key,
                         AnyButtonStyle(EditorViewportToolbarButtonStyle(isActive: isActive)))
    }
}

private struct EditorViewportToolbarButtonStyle: ButtonStyle, Hashable {
    let isActive: Bool

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let clear = Color(r: 0, g: 0, b: 0, a: 0)
        // Chips live inside the floating viewport bar: transparent at rest,
        // state-layer washes on hover/press, an accent tint when active —
        // no per-chip borders (the bar carries the chrome).
        let bg: Color = {
            if !configuration.isEnabled { return clear }
            if isActive {
                let selected = theme.colors.accentMuted
                if configuration.isPressed { return selected.composited(over: theme.colors.stateLayerPressed) }
                if configuration.isHovered { return selected.composited(over: theme.colors.stateLayerHover) }
                return selected
            }
            if configuration.isPressed { return theme.colors.stateLayerPressed }
            if configuration.isHovered { return theme.colors.stateLayerHover }
            return clear
        }()
        let border: Color = configuration.isFocused ? theme.colors.focusRing : clear
        let borderWidth: Float = configuration.isFocused ? 2 : 0
        let foreground: SemanticColorRef = isActive ? .accent : .onSurfaceVariant

        return Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
                .font(SemanticFontRef.label)
                .foregroundColor(foreground)
        }
        .frame(height: 26, minWidth: 28)
        .padding(horizontal: 7, vertical: 0)
        .background(bg)
        .cornerRadius(6)
        .border(border, width: borderWidth)
        .opacity(configuration.isEnabled ? 1 : 0.55)
        .animation(.semantic(.snappy, in: theme), value: configuration.interactionKey)
    }
}
