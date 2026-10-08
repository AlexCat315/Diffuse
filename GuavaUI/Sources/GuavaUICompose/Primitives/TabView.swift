import GuavaUIRuntime

public struct TabItem<ID: Hashable> {
    public let id: ID
    public let label: String
    public let content: AnyView
    public var isEnabled: Bool = true

    public init<C: View>(_ label: String,
                         id: ID, isEnabled: Bool = true,
                         @ViewBuilder content: () -> C) {
        self.id = id
        self.label = label
        self.content = AnyView(content())
        self.isEnabled = isEnabled
    }
}

public struct TabView<ID: Hashable>: View {
    public let selection: Binding<ID>
    public let tabs: [TabItem<ID>]

    public init(selection: Binding<ID>, tabs: [TabItem<ID>]) {
        self.selection = selection
        self.tabs = tabs
        precondition(Set(tabs.map(\.id)).count == tabs.count, "Tab IDs must be unique")
    }

    public var body: some View {
        let enabled = tabs.filter(\.isEnabled).map(\.id)
        let tabStop = enabled.contains(selection.wrappedValue) ? selection.wrappedValue : enabled.first
        RovingFocusHost(enabledItems: enabled.map { AnyHashable($0) }, selection: { AnyHashable(selection.wrappedValue) },
                        onSelect: { if let id = $0.base as? ID { selection.wrappedValue = id } }) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                Row(alignment: .center, spacing: 0) {
                    for tab in tabs {
                        AnyView(_TabBarItem(label: tab.label, isSelected: selection.wrappedValue == tab.id,
                                            isEnabled: tab.isEnabled, onSelect: { selection.wrappedValue = tab.id })
                            .modifier(RovingItemModifier(id: AnyHashable(tab.id), isTabStop: tab.id == tabStop)))
                    }
                    Spacer()
                }.background(.surface)
                Divider()
                if let active = tabs.first(where: { $0.id == selection.wrappedValue }) {
                    active.content.flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
                }
            }
        }
    }
}

struct _TabBarItem: View {
    let label: String
    let isSelected: Bool
    let isEnabled: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(label, isEnabled: isEnabled, isSelected: isSelected, action: onSelect)
            .accessibility { $0.role = .tab; $0.state.isSelected = isSelected }
            .buttonStyle(.tab)
    }
}
