import GuavaUIRuntime

/// Flat IDE tab with an accent underline and full keyboard/hover focus states.
/// The same style can be used for document tabs and tool-panel tabs.
public struct TabButtonStyle: ButtonStyle, Hashable {
    public var height: Float

    public init(height: Float = 28) { self.height = height }

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let colors = configuration.theme.colors
        let fill = configuration.isSelected ? colors.surfaceVariant
            : configuration.isPressed ? colors.stateLayerPressed
            : configuration.isHovered ? colors.stateLayerHover : .clear
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                AnyView(configuration.label)
                    .font(.label)
                    .foregroundColor(!configuration.isEnabled ? .onSurfaceDisabled
                        : configuration.isSelected ? .onSurface : .onSurfaceVariant)
            }
            .padding(horizontal: 10)
            .frame(height: height - 2)
            Box { EmptyView() }
                .frame(height: 2)
                .background(configuration.isSelected ? colors.accent : .clear)
                .debugName("tab-selection-indicator")
        }
        .background(fill)
        .border(configuration.isFocused ? colors.focusRing : .clear, width: 1)
        .animation(.semantic(.fast, in: configuration.theme), value: configuration.interactionKey)
    }
}

public extension ButtonStyle where Self == TabButtonStyle {
    static var tab: TabButtonStyle { TabButtonStyle() }
}
