import GuavaUIRuntime

struct RailDestinationLabel<ID: Hashable>: View {
    let item: SidebarItem<ID>
    let showsLabels: Bool
    let iconExtent: Float
    var isExpanded: Bool? = nil

    var body: some View {
        Box(direction: .column, alignItems: .center, spacing: 4) {
            Box(direction: .column, alignItems: .center, justifyContent: .center) {
                // Extent has already resolved icon roles and scaling. Preserve
                // replacements while avoiding a second application of scaling.
                Icon(item.icon ?? UIIcons.File.file, size: iconExtent).iconScaling(.fixed).accessibilityHidden()
                if item.badge != nil {
                    Box {}.frame(width: 6, height: 6).background(item.isEnabled ? .accent : .onSurfaceDisabled)
                        .cornerRadius(3).absolutePosition(top: 0, right: 0).accessibilityHidden()
                }
                if let isExpanded {
                    Icon(isExpanded ? UIIcons.Action.minus : UIIcons.Action.plus, size: 10)
                        .background(.surface).accessibilityHidden().absolutePosition(top: -4, right: -7)
                }
            }.frame(width: iconExtent, height: iconExtent).flex(0, shrink: 0)
            if showsLabels {
                Text(item.title, alignment: .center).font(.caption).frame(width: .percent(100))
                    .debugName("sidebar-title-\(item.id)")
            }
        }.frame(width: .percent(100), minWidth: 0)
    }
}

struct RailDestinationStyle: ButtonStyle {
    let minimumHeight: Float
    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        Box(direction: .row, alignItems: .stretch) {
            Box {}.frame(width: 2).background(c.isSelected ? c.theme.colors.accent : .clear)
                .flex(0, shrink: 0).accessibilityHidden().debugName("rail-selection-indicator")
            AnyView(c.label).padding(horizontal: 4, vertical: 8).flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
            Box {}.frame(width: 2).flex(0, shrink: 0).accessibilityHidden()
        }
        .frame(width: .percent(100), minHeight: minimumHeight)
        .foregroundColor(c.isEnabled ? c.isSelected ? .onSurface : .onSurfaceVariant : .onSurfaceDisabled)
        .selectionHighlight(.sidebar, isSelected: c.isSelected, isHovered: c.isHovered, isPressed: c.isPressed)
        .border(c.isFocused ? c.theme.colors.focusRing : .clear, width: 1)
    }
}
