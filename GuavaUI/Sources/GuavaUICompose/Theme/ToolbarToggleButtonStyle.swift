import GuavaUIRuntime

/// Quiet selection for dense toolbars; primary actions retain solid fills.
public struct ToolbarToggleButtonStyle: ButtonStyle {
    public var height: Float = 26
    public var minWidth: Float = 28

    public init(_ configure: (inout Self) -> Void = { _ in }) { configure(&self) }

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let colors = configuration.theme.colors
        let fill = configuration.isPressed ? colors.stateLayerPressed
            : configuration.isHovered ? colors.stateLayerHover
            : configuration.isSelected ? colors.accentMuted : .clear
        return Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label).font(.label)
                .foregroundColor(configuration.isSelected ? SemanticColorRef.accent : .onSurfaceVariant)
        }
        .padding(horizontal: 6)
        .frame(height: height, minWidth: minWidth)
        .background(fill).cornerRadius(configuration.theme.radius.sm)
        .border(configuration.isFocused ? colors.focusRing : .clear, width: 1)
        .opacity(configuration.isEnabled ? 1 : 0.55)
    }
}

public extension ButtonStyle where Self == ToolbarToggleButtonStyle {
    static var toolToggle: ToolbarToggleButtonStyle { ToolbarToggleButtonStyle() }
}
