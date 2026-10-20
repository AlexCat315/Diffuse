internal import GuavaUI
internal import GuavaUIRuntime

struct EditorChromeTokens: ThemeExtension {
    var agent = Color(red: 0xF0, green: 0x7D, blue: 0x96)
    static let defaultValue = Self()
    static let agentColor = SemanticColorRef { $0.extensions[Self.self].agent }
}

/// Shared, bounded controls for the title bar, activity rail and context header.
struct EditorChromeButtonStyle: ButtonStyle {
    var height: Float = 26
    var agent = false

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let colors = configuration.theme.colors
        let ink = agent ? configuration.theme.extensions[EditorChromeTokens.self].agent : colors.onSurface
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
    }
}
