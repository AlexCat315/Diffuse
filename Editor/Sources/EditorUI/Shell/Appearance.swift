internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime

/// Shared, bounded controls for the title bar, activity rail and context header.
struct EditorChromeButtonStyle: ButtonStyle {
    var height: Float = 26
    var agent = false

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let colors = configuration.theme.colors
        let ink = agent ? configuration.theme.extensions[EditorThemeTokens.self].assistant : colors.onSurface
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label).font(.label)
                .foregroundColor(!configuration.isEnabled ? colors.onSurfaceMuted
                    : configuration.isSelected || agent ? ink : colors.onSurfaceVariant)
        }
        .padding(horizontal: 8)
        .frame(height: height, minWidth: height)
        .background(configuration.isPressed ? colors.stateLayerPressed
            : configuration.isSelected ? colors.surfaceVariant
            : configuration.isHovered ? colors.stateLayerHover : .clear)
        .cornerRadius(6)
        .border(configuration.isFocused ? colors.focusRing : .clear, width: 1)
        .animation(motion: .fast, value: configuration.interactionKey)
    }
}
