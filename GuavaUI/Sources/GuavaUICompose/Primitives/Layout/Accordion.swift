import GuavaUIRuntime

public struct AccordionItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    public var isEnabled = true
    public let content: AnyView
    public init<C: View>(_ id: ID, _ title: String, isEnabled: Bool = true, @ViewBuilder content: () -> C) {
        self.id = id; self.title = title; self.isEnabled = isEnabled; self.content = AnyView(content())
    }
}
public struct Accordion<ID: Hashable>: View {
    public let items: [AccordionItem<ID>]
    public let expanded: Binding<Set<ID>>
    public var allowsMultiple = false
    public var isEnabled = true
    @State private var focused: ID?
    public init(_ items: [AccordionItem<ID>], expanded: Binding<Set<ID>>, configure: (inout Self) -> Void = { _ in }) {
        self.items = items; self.expanded = expanded; configure(&self)
        precondition(Set(items.map(\.id)).count == items.count, "Accordion IDs must be unique")
    }
    public var body: some View {
        let enabled = items.filter { isEnabled && $0.isEnabled }.map(\.id)
        let tabStop = focused.flatMap { enabled.contains($0) ? $0 : nil } ?? enabled.first
        return RovingFocusHost(enabledItems: enabled.map { AnyHashable($0) }, selection: { focused.map { AnyHashable($0) } },
                               onSelect: { focused = $0.base as? ID }, command: { event in
                                   guard event.modifiers.isEmpty else { return nil }
                                   switch event.scancode {
                                   case Scancode.arrowUp: return .previous
                                   case Scancode.arrowDown: return .next
                                   case Scancode.home: return .first
                                   case Scancode.end: return .last
                                   default: return nil
                                   }
                               }) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                for (index, item) in items.enumerated() {
                    AnyView(Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        Button(isEnabled: isEnabled && item.isEnabled, action: { toggle(item.id); focused = item.id }) {
                            Row(alignment: .center, spacing: 8) {
                                Text(item.title).font(.bodyStrong).flex(1, shrink: 1).frame(minWidth: 0)
                                Icon(expanded.wrappedValue.contains(item.id) ? UIIcons.Navigation.chevronDown : UIIcons.Navigation.chevronRight, size: .small).accessibilityHidden()
                            }.padding(12)
                        }.buttonStyle(AccordionHeaderStyle())
                            .compositionLocal(ActionControlAccessibility.isExpanded, expanded.wrappedValue.contains(item.id))
                            .modifier(RovingItemModifier(id: AnyHashable(item.id), isTabStop: tabStop == item.id))
                        AnimatedVisibility(isVisible: expanded.wrappedValue.contains(item.id)) { item.content.padding(12) }
                        if index < items.count - 1 { Divider() }
                    }.id(item.id))
                }
            }.background(.surfaceRaised).border(.border, width: 1).cornerRadius(.panelRadius).clipped()
        }
    }
    public func toggle(_ id: ID) {
        guard isEnabled, items.contains(where: { $0.id == id && $0.isEnabled }) else { return }
        if expanded.wrappedValue.contains(id) { expanded.wrappedValue.remove(id) }
        else if allowsMultiple { expanded.wrappedValue.insert(id) }
        else { expanded.wrappedValue = [id] }
    }
}
private struct AccordionHeaderStyle: ButtonStyle {
    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        Box(direction: .row, alignItems: .center) { AnyView(c.label).flex(1, shrink: 1) }.flex(1, shrink: 1)
            .foregroundColor(c.isEnabled ? .onSurface : .onSurfaceDisabled)
            .background(c.isPressed ? c.theme.colors.stateLayerPressed : c.isHovered ? c.theme.colors.stateLayerHover : .clear)
            .border(c.isFocused ? c.theme.colors.focusRing : .clear, width: 2)
            .opacity(c.isEnabled ? 1 : 0.55)
    }
}
