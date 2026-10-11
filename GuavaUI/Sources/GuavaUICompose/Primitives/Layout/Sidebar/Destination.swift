import GuavaUIRuntime

struct SidebarDestination<ID: Hashable>: View {
    let item: SidebarItem<ID>
    let selection: Binding<ID?>
    let isTabStop: Bool
    let iconWidth: Float?
    var body: some View {
        Button(isEnabled: item.isEnabled, isSelected: selection.wrappedValue == item.id,
               action: { selection.wrappedValue = item.id }) {
            Row(alignment: .center, spacing: 10) {
                if let iconWidth {
                    Box(direction: .row, alignItems: .center, justifyContent: .center) {
                        if let icon = item.icon {
                            Icon(icon, size: item.iconSize).accessibilityHidden()
                        }
                    }.frame(width: iconWidth).flex(0, shrink: 0)
                }
                Text(item.title).font(.label).flex(1, shrink: 1).frame(minWidth: 0)
                    .debugName("sidebar-title-\(item.id)")
                if let badge = item.badge {
                    Badge(badge, tone: .neutral) { $0.isEnabled = item.isEnabled }
                        .flex(0, shrink: 0).accessibilityHidden()
                        .debugName("sidebar-badge-\(item.id)")
                }
            }
        }.buttonStyle(SidebarItemStyle())
            .compositionLocal(ActionControlAccessibility.label, item.title)
            .compositionLocal(ActionControlAccessibility.value, item.badge ?? "")
            .modifier(RovingItemModifier(id: AnyHashable(item.id), isTabStop: isTabStop))
            .modifier(SidebarSelectionReveal(isSelected: selection.wrappedValue == item.id))
            .debugName("sidebar-item-\(item.id)").id(item.id)
    }
}

private struct SidebarSelectionReveal: ViewModifier {
    let isSelected: Bool
    private static var key: String { "__sidebar.selected" }
    func apply(node: Node) {
        let previous = node.attachments[Self.key] as? Bool
        node.attachments[Self.key] = isSelected
        guard isSelected, previous != true else { return }
        let prior = node.layoutDidUpdate
        node.layoutDidUpdate = { node in
            prior?(node)
            if node.attachments[Self.key] as? Bool == true { ScrollReveal.reveal(node, nearestOnly: true) }
            node.layoutDidUpdate = prior
        }
    }
}

struct SidebarItemStyle: ButtonStyle {
    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        Box(direction: .row, alignItems: .center) { AnyView(c.label).flex(1, shrink: 1).frame(minWidth: 0) }
            .flex(1, shrink: 1).frame(minWidth: 0, minHeight: 38)
            .foregroundColor(c.isEnabled ? c.isSelected ? .onSurface : .onSurfaceVariant : .onSurfaceDisabled)
            .padding(horizontal: 10, vertical: 7)
            .background(fill(for: c))
            .cornerRadius(c.theme.radius.md).border(c.isFocused ? c.theme.colors.focusRing : .clear, width: c.isFocused ? 2 : 0)
    }

    /// Selection is a resting state, not a replacement for feedback: a selected
    /// destination still answers hover and press, by layering the same state
    /// layer over the selection fill. Disabled rows answer nothing.
    private func fill(for c: ButtonStyleConfiguration) -> Color {
        let base: Color = c.isSelected ? c.theme.colors.surfaceVariant : .clear
        guard c.isEnabled else { return base }
        if c.isPressed { return base.composited(over: c.theme.colors.stateLayerPressed) }
        if c.isHovered { return base.composited(over: c.theme.colors.stateLayerHover) }
        return base
    }
}
