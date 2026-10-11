import GuavaUIRuntime

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
        precondition(Set(sections.map(\.id)).count == sections.count, "Sidebar section IDs must be unique")
    }
    public var body: some View {
        let enabled = sections.flatMap(\.items).filter(\.isEnabled).map(\.id)
        let tabStop = selection.wrappedValue.flatMap { enabled.contains($0) ? $0 : nil } ?? enabled.first
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Box(direction: .column, alignItems: .stretch) { header }.flex(0, shrink: 0)
            RovingFocusHost(enabledItems: enabled.map { AnyHashable($0) }, selection: { selection.wrappedValue.map { AnyHashable($0) } },
                            onSelect: { if let id = $0.base as? ID { selection.wrappedValue = id } }, command: { event in
                                guard event.modifiers.isEmpty else { return nil }
                                switch event.scancode {
                                case Scancode.arrowUp: return .previous
                                case Scancode.arrowDown: return .next
                                case Scancode.home: return .first
                                case Scancode.end: return .last
                                default: return nil
                                }
                            }) {
                // Overlay gutter: a reserved lane insets only the trailing edge,
                // which would make every selected destination sit 12pt further
                // from the right edge than from the left.
                ScrollView(.vertical, scrollbarGutter: .overlay) {
                    Box(direction: .column, alignItems: .stretch, spacing: 10) {
                        for section in sections {
                            AnyView(IconMetricsReader { metrics in
                                // A section owns one leading lane even when some
                                // destinations omit their icon or use another role.
                                let iconWidth = section.items.compactMap { item in
                                    item.icon.map { _ in metrics.size(item.iconSize) }
                                }.max()
                                Box(direction: .column, alignItems: .stretch, spacing: 3) {
                                    if !section.title.isEmpty {
                                        Text(section.title.uppercased()).font(.caption).foregroundColor(.onSurfaceMuted)
                                            .padding(horizontal: 8, vertical: 8)
                                    }
                                    for item in section.items {
                                        SidebarDestination(item: item, selection: selection,
                                                           isTabStop: item.id == tabStop, iconWidth: iconWidth)
                                    }
                                }
                            }.id(section.id))
                        }
                    }.padding(10).flex(0, shrink: 0)
                }.flex(1, shrink: 1, basis: 0).frame(minHeight: 0)
            }
            Box(direction: .column, alignItems: .stretch) { footer }.flex(0, shrink: 0)
        }.background(.surface).frame(minWidth: 0, minHeight: 0)
    }
}

public extension Sidebar where Header == EmptyView, Footer == EmptyView {
    init(selection: Binding<ID?>, sections: [SidebarSection<ID>]) {
        self.init(selection: selection, sections: sections, header: { EmptyView() }, footer: { EmptyView() })
    }
}
