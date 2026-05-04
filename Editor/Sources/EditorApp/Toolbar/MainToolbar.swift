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
        let bg: Color = {
            if !configuration.isEnabled { return theme.colors.surfaceSunken }
            if isActive {
                if configuration.isPressed { return theme.colors.accentPressed }
                if configuration.isHovered { return theme.colors.accentHover }
                return theme.colors.accent
            }
            if configuration.isPressed { return theme.colors.surfaceRaised }
            if configuration.isHovered { return theme.colors.surfaceVariant }
            return theme.colors.surfaceSunken
        }()
        let border: Color = configuration.isFocused ? theme.colors.focusRing : theme.colors.border
        let borderWidth: Float = configuration.isFocused ? 2 : 1

        return Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
                .font(SemanticFontRef.label)
                .foregroundColor(isActive ? SemanticColorRef.onAccent : SemanticColorRef.onSurfaceVariant)
        }
        .frame(width: 28, height: 26)
        .padding(horizontal: 0, vertical: 0)
        .background(bg)
        .cornerRadius(3)
        .border(border, width: borderWidth)
        .opacity(configuration.isEnabled ? 1 : 0.55)
        .animation(.semantic(.snappy, in: theme), value: configuration.interactionKey)
    }
}
