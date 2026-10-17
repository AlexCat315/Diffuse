internal import GuavaUIRuntime

struct TabOverflowStrip<ID: Hashable>: View {
    let tabs: [TabItem<ID>]
    let selection: Binding<ID>
    let tabStop: ID?
    let isEnabled: Bool
    let variant: TabVariant
    let indicator: IndicatorPlacement
    let focusRequest: RovingFocusRequest
    @State private var hidden: Set<ID> = []
    @State private var isPresented = false

    var body: some View {
        if !isEnabled && isPresented { isPresented = false }
        return ContainerSizeReader { size in
            let maximumHeaderWidth = size.width > 0
                ? Float(max(44, size.width - (tabs.count > 1 ? 44 : 0) - (variant == .segmented ? 2 : 0)))
                : Float.greatestFiniteMagnitude
            return ScrollView(.horizontal, scrollbarGutter: .overlay) {
                TabOverflowLayout(selectedIndex: tabs.firstIndex { $0.id == selection.wrappedValue },
                                  spacing: variant == .segmented ? 2 : 0,
                                  onHidden: { indices in
                    let next = Set(indices.map { tabs[$0].id })
                    guard next != hidden else { return }
                    if isPresented {
                        focusRequest.target = AnyHashable(selection.wrappedValue)
                        isPresented = false
                    }
                    hidden = next
                }) {
                    for tab in tabs {
                        AnyView(TabStripItem(tab: tab, selection: selection, isEnabled: isEnabled,
                                            variant: variant, indicator: indicator, tabStop: tabStop,
                                            maximumWidth: maximumHeaderWidth).id(tab.id))
                    }
                    Box(direction: .column, alignItems: .flexStart, spacing: 0) {
                        Button(icon: .resource(UIIcons.Action.moreHorizontal), isEnabled: isEnabled,
                               tooltip: "More tabs") { isPresented.toggle() }
                            .buttonStyle(.ghost).frame(minWidth: 44, minHeight: 44)
                            .compositionLocal(ActionControlAccessibility.label, "More tabs")
                            .compositionLocal(ActionControlAccessibility.isExpanded, isPresented)
                        _PopoverOverlayHost(isPresented: isPresented, width: nil, placement: .end,
                                            onDismiss: { isPresented = false }) {
                            Menu(tabs.filter { hidden.contains($0.id) }.map { tab in
                                .item(MenuItem(id: AnyHashable(tab.id), title: tab.label,
                                               isEnabled: isEnabled && tab.isEnabled,
                                               isSelected: tab.id == selection.wrappedValue) {
                                    selection.wrappedValue = tab.id
                                    focusRequest.target = AnyHashable(tab.id)
                                    isPresented = false
                                })
                            }, onItemActivated: { isPresented = false }, onDismiss: { isPresented = false })
                            .compositionLocal(MenuRowMetrics.minimumHeight, 44)
                        }
                    }
                }.frame(width: .percent(100), minWidth: tabs.isEmpty ? 0 : tabs.count > 1 ? 90 : 44).flex(0, shrink: 0)
            }.flex(0, shrink: 0)
        }
    }
}
