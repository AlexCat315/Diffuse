import GuavaUICompose
import GuavaUIRuntime

struct EditorIconButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var size: Float

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let background: Color = {
            if isActive {
                if configuration.isPressed { return theme.colors.accentPressed }
                if configuration.isHovered { return theme.colors.accentHover }
                return theme.colors.accent
            }
            if configuration.isPressed { return theme.colors.stateLayerPressed }
            if configuration.isHovered { return theme.colors.stateLayerHover }
            return theme.colors.surfaceSunken
        }()
        let foreground: SemanticColorRef = {
            if !configuration.isEnabled { return .onSurfaceMuted }
            return isActive ? .onAccent : .onSurfaceVariant
        }()
        let border = configuration.isFocused
            ? theme.colors.focusRing
            : Color(r: 0, g: 0, b: 0, a: 0)
        let borderWidth: Float = configuration.isFocused ? 2 : 0

        return Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
                .foregroundColor(foreground)
        }
        .frame(width: size, height: size)
        .background(background)
        .cornerRadius(4)
        .border(border, width: borderWidth)
        .opacity(configuration.isEnabled ? 1 : 0.55)
        .animation(.semantic(.snappy, in: theme), value: configuration.interactionKey)
    }
}
