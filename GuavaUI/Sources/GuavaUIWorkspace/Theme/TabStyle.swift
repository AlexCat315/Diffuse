import GuavaUICompose
import GuavaUIRuntime

/// Panel tabs are selection blocks inside the pane's tab bar: no rules above
/// or between tabs, so the rounded pane stays one continuous surface.
struct WorkspaceTabStyle: ButtonStyle {
    let height: Float

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let colors = configuration.theme.colors
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
        }
        .padding(horizontal: 9)
        .frame(height: height - 8)
        .background(configuration.isSelected ? colors.surfaceVariant
            : configuration.isHovered ? colors.stateLayerHover : .clear)
        .cornerRadius(6)
        .border(configuration.isFocused ? colors.focusRing : .clear, width: 1)
    }
}
