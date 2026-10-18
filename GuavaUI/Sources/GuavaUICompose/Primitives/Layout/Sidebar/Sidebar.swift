import GuavaUIRuntime

/// Navigation chrome with independent header/footer slots and one Tab stop among enabled destinations.
public struct Sidebar<ID: Hashable, Header: View, Footer: View>: View {
    public let selection: Binding<ID?>
    public let sections: [SidebarSection<ID>]
    public let minimumRowHeight: Float
    private let presentation: SidebarPresentation
    private let expansion: Binding<Set<ID>>?
    private let onActivate: (ID) -> Void
    private let header: Header
    private let footer: Footer
    @State private var localExpanded: Set<ID> = []
    @State private var hierarchySession = SidebarHierarchySession<ID>()
    public init(selection: Binding<ID?>, sections: [SidebarSection<ID>], presentation: SidebarPresentation = .expanded,
                expanded: Binding<Set<ID>>? = nil,
                minimumRowHeight: Float = 38,
                onActivate: @escaping (ID) -> Void = { _ in },
                @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.selection = selection; self.sections = sections; self.header = header(); self.footer = footer()
        self.minimumRowHeight = minimumRowHeight.isFinite ? max(0, minimumRowHeight) : 38
        self.onActivate = onActivate
        self.presentation = presentation
        self.expansion = expanded
        let ids = SidebarHierarchy(sections).entries.map { $0.item.id }
        precondition(Set(ids).count == ids.count, "Sidebar item IDs must be unique")
        precondition(Set(sections.map(\.id)).count == sections.count, "Sidebar section IDs must be unique")
    }
    public var body: some View {
        let hierarchy = SidebarHierarchy(sections)
        let expanded = expansion ?? $localExpanded
        let enabled = hierarchy.entries.filter { $0.isEnabled && $0.isVisible(in: expanded.wrappedValue) }.map { $0.item.id }
        let tabStop = hierarchySession.tabStop(in: hierarchy, expanded: expanded.wrappedValue, selection: selection.wrappedValue)
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Box(direction: .column, alignItems: .stretch) { header }.flex(0, shrink: 0)
            SidebarHierarchyHost(hierarchy: hierarchy, expanded: expanded, selection: selection, session: hierarchySession) {
            RovingFocusHost(enabledItems: enabled.map { AnyHashable($0) }, selection: {
                                hierarchySession.tabStop(in: hierarchy, expanded: expanded.wrappedValue,
                                                         selection: selection.wrappedValue).map(AnyHashable.init)
                            }, onSelect: {
                                if let id = $0.base as? ID, hierarchy.entry(id)?.isBranch == false { selection.wrappedValue = id }
                            }, command: { event in
                                guard event.modifiers.isEmpty else { return nil }
                                switch event.scancode {
                                case Scancode.arrowUp: return .previous
                                case Scancode.arrowDown: return .next
                                case Scancode.home: return .first
                                case Scancode.end: return .last
                                default: return nil
                                }
                            }, focusRequest: hierarchySession.focus) {
                // Overlay gutter: a reserved lane insets only the trailing edge,
                // which would make every selected destination sit 12pt further
                // from the right edge than from the left.
                ScrollView(.vertical, scrollbarGutter: .overlay) {
                    Box(direction: .column, alignItems: .stretch, spacing: 10) {
                        for (index, section) in sections.enumerated() {
                            AnyView(IconMetricsReader { metrics in
                                // A section owns one leading lane even when some
                                // destinations omit their icon or use another role.
                                let entries: [SidebarHierarchy<ID>.Entry] = hierarchy.groups[index]
                                let iconWidth = entries.compactMap { entry in
                                    entry.item.icon.map { _ in metrics.size(entry.item.iconSize) }
                                }.max()
                                Box(direction: .column, alignItems: .stretch, spacing: 3) {
                                    if !section.title.isEmpty && !presentation.isRail {
                                        Text(section.title).font(.caption).foregroundColor(.onSurfaceMuted)
                                            .padding(horizontal: 8, vertical: 8)
                                    }
                                    for entry in entries {
                                        AnyView(AnimatedVisibility(isVisible: entry.isVisible(in: expanded.wrappedValue),
                                                                   transition: .identity, retainsContent: true) {
                                        SidebarDestination(entry: entry, selection: selection, expanded: expanded,
                                                           isTabStop: entry.item.id == tabStop, iconWidth: iconWidth,
                                                           minimumRowHeight: minimumRowHeight, onActivate: onActivate,
                                                           presentation: presentation,
                                                           iconExtent: metrics.size(entry.item.icon == nil ? .medium : entry.item.iconSize),
                                                           disclosureLane: entries.contains { $0.isBranch },
                                                           contextLabel: hierarchy.context(for: entry))
                                        }.id(entry.item.id))
                                    }
                                }
                            }.id(section.id))
                        }
                    }.padding(presentation.isRail ? 0 : 10).flex(0, shrink: 0)
                }.flex(1, shrink: 1, basis: 0).frame(minHeight: 0)
            }
            }
            Box(direction: .column, alignItems: .stretch) { footer }.flex(0, shrink: 0)
        }.background(.surface).frame(width: presentation.railWidth.map(FrameDimension.points) ?? .auto,
                                    minWidth: 0, minHeight: 0)
    }
}

public extension Sidebar where Header == EmptyView, Footer == EmptyView {
    init(selection: Binding<ID?>, sections: [SidebarSection<ID>], presentation: SidebarPresentation = .expanded,
         expanded: Binding<Set<ID>>? = nil,
         minimumRowHeight: Float = 38,
         onActivate: @escaping (ID) -> Void = { _ in }) {
        self.init(selection: selection, sections: sections, presentation: presentation, expanded: expanded, minimumRowHeight: minimumRowHeight,
                  onActivate: onActivate, header: { EmptyView() }, footer: { EmptyView() })
    }
}
