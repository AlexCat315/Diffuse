import GuavaUIRuntime

/// IDE tab with the shared selection pill and full keyboard/hover focus states.
/// The same style can be used for document tabs and tool-panel tabs.
///
/// The tab takes its fill, radius and insets from `SelectionAppearance` rather
/// than composing its own, so a tab strip, a list row and a sidebar destination
/// are the same selection three times over. A hard-edged full-bleed band read
/// as a box sitting *in* the header instead of a tab that belongs to it.
public struct TabButtonStyle: ButtonStyle, Hashable {
    public var height: Float

    public init(height: Float = 28) { self.height = height }

    public func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let appearance = SelectionAppearance.resolve(.navigation, theme: theme)
        // The indicator rides the bottom of the strip, so the pill keeps a
        // little more room below than above.
        let top = appearance.verticalInset
        let bottom = appearance.verticalInset + 2
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                AnyView(configuration.label)
                    .font(.label)
                    .foregroundColor(!configuration.isEnabled ? .onSurfaceDisabled
                        : configuration.isSelected ? .onSurface : .onSurfaceVariant)
            }
            .padding(horizontal: 10, vertical: 4)
            .frame(minHeight: max(0, height - top - bottom))
            Box { EmptyView() }
                .frame(height: 2)
                .background(configuration.isSelected ? theme.colors.accent : .clear)
                .debugName("tab-selection-indicator")
        }
        .padding(horizontal: appearance.horizontalInset, vertical: top)
        .padding(horizontal: 0, vertical: bottom - top)
        .selectionHighlight(.navigation,
                            isSelected: configuration.isSelected,
                            isHovered: configuration.isHovered,
                            isPressed: configuration.isPressed)
        .border(configuration.isFocused ? theme.colors.focusRing : .clear, width: 1)
        .animation(.semantic(.fast, in: theme), value: configuration.interactionKey)
    }
}

public extension ButtonStyle where Self == TabButtonStyle {
    static var tab: TabButtonStyle { TabButtonStyle() }
}