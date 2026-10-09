import GuavaUIRuntime

public struct SidebarItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    public var badge: String?
    public var isEnabled = true
    public init(_ id: ID, _ title: String, configure: (inout Self) -> Void = { _ in }) {
        self.id = id; self.title = title; configure(&self)
    }
}

public struct SidebarSection<ID: Hashable>: Identifiable {
    public let id: String
    public let title: String
    public let items: [SidebarItem<ID>]
    public init(_ id: String, title: String = "", items: [SidebarItem<ID>]) { self.id = id; self.title = title; self.items = items }
}

/// Navigation chrome with independent header/footer slots and one Tab stop among enabled destinations.
public struct Sidebar<ID: Hashable, Header: View, Footer: View>: View {
    public let selection: Binding<ID?>
    public let sections: [SidebarSection<ID>]
    private let header: Header
    private let footer: Footer
    public init(selection: Binding<ID?>, sections: [SidebarSection<ID>],
                @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.selection = selection; self.sections = sections; self.header = header(); self.footer = footer()
        let ids = sections.flatMap(\.items).map(\.id)
        precondition(Set(ids).count == ids.count, "Sidebar item IDs must be unique")
    }
    public var body: some View {
        let enabled = sections.flatMap(\.items).filter(\.isEnabled).map(\.id)
        let tabStop = selection.wrappedValue.flatMap { enabled.contains($0) ? $0 : nil } ?? enabled.first
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            header.flex(0, shrink: 0)
            RovingFocusHost(enabledItems: enabled.map { AnyHashable($0) }, selection: { selection.wrappedValue.map { AnyHashable($0) } },
                            onSelect: { if let id = $0.base as? ID { selection.wrappedValue = id } }) {
                ScrollView(.vertical, scrollbarGutter: .stable) {
                    Box(direction: .column, alignItems: .stretch, spacing: 10) {
                        for section in sections {
                            AnyView(Box(direction: .column, alignItems: .stretch, spacing: 3) {
                                if !section.title.isEmpty {
                                    Text(section.title.uppercased()).font(.caption).foregroundColor(.onSurfaceMuted)
                                        .padding(horizontal: 8, vertical: 8)
                                }
                                for item in section.items {
                                    AnyView(Button(isEnabled: item.isEnabled, isSelected: selection.wrappedValue == item.id,
                                                   action: { selection.wrappedValue = item.id }) {
                                        Row(alignment: .center, spacing: 8) {
                                            Text(item.title).lineLimit(1).font(.label)
                                            Spacer()
                                            if let badge = item.badge { Badge(badge, tone: .neutral) }
                                        }
                                    }.buttonStyle(SidebarItemStyle())
                                        .modifier(RovingItemModifier(id: AnyHashable(item.id), isTabStop: item.id == tabStop))
                                        .debugName("sidebar-item-\(item.id)").id(item.id))
                                }
                            }.id(section.id))
                        }
                    }.padding(10).flex(0, shrink: 0)
                }.flex(1, shrink: 1, basis: 0).frame(minHeight: 0)
            }
            footer.flex(0, shrink: 0)
        }.background(.surface).frame(minWidth: 0, minHeight: 0)
    }
}

public extension Sidebar where Header == EmptyView, Footer == EmptyView {
    init(selection: Binding<ID?>, sections: [SidebarSection<ID>]) {
        self.init(selection: selection, sections: sections, header: { EmptyView() }, footer: { EmptyView() })
    }
}

private struct SidebarItemStyle: ButtonStyle {
    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        Row(alignment: .center) { AnyView(c.label) }.flex(1, shrink: 1)
            .foregroundColor(c.isEnabled ? c.isSelected ? .onSurface : .onSurfaceVariant : .onSurfaceDisabled)
            .padding(horizontal: 8, vertical: 7)
            .background(c.isSelected ? c.theme.colors.surfaceVariant : c.isHovered ? c.theme.colors.stateLayerHover : .clear)
            .cornerRadius(6).border(c.isFocused ? c.theme.colors.focusRing : .clear, width: c.isFocused ? 2 : 0)
    }
}
