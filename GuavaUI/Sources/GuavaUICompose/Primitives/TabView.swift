import GuavaUIRuntime

private struct _TabItemInteractionKey: Equatable, Sendable {
    let isSelected: Bool
}

public struct TabItem<ID: Hashable> {
    public let id: ID
    public let label: String
    public let content: AnyView

    public init<C: View>(_ label: String,
                         id: ID,
                         @ViewBuilder content: () -> C) {
        self.id = id
        self.label = label
        self.content = AnyView(content())
    }
}

public struct TabView<ID: Hashable>: View {
    public let selection: Binding<ID>
    public let tabs: [TabItem<ID>]

    public init(selection: Binding<ID>, tabs: [TabItem<ID>]) {
        self.selection = selection
        self.tabs = tabs
    }

    public var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Row(alignment: .center, spacing: 0) {
                for tab in tabs {
                    _TabBarItem(
                        label: tab.label,
                        isSelected: selection.wrappedValue == tab.id,
                        onSelect: { selection.wrappedValue = tab.id }
                    )
                }
                Spacer()
            }
            .background(.surfaceVariant)

            Divider()

            if let active = tabs.first(where: { $0.id == selection.wrappedValue }) {
                active.content
            }
        }
    }
}

struct _TabBarItem: View {
    let label: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                Text(label)
                    .font(.bodyStrong)
                    .foregroundColor(isSelected ? .accent : .onSurfaceMuted)
                    .padding(horizontal: 12, vertical: 8)
                if isSelected {
                    Box { EmptyView() }
                        .frame(height: 2)
                        .background(.accent)
                } else {
                    Box { EmptyView() }
                        .frame(height: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.semantic(.fast), value: _TabItemInteractionKey(isSelected: isSelected))
    }
}
