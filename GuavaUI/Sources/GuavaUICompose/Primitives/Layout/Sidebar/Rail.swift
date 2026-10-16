import GuavaUIRuntime

/// Compact destination navigation. Applications choose it for medium/expanded
/// surfaces and use NavigationDrawer for compact surfaces.
public struct NavigationRail<ID: Hashable, Header: View, Footer: View>: View {
    private let selection: Binding<ID?>
    private let items: [SidebarItem<ID>]
    private let showsLabels: Bool
    private let onActivate: (ID) -> Void
    private let header: Header
    private let footer: Footer

    public init(
        selection: Binding<ID?>, items: [SidebarItem<ID>], showsLabels: Bool = true,
        onActivate: @escaping (ID) -> Void = { _ in },
        @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer
    ) {
        self.selection = selection
        self.items = items
        self.showsLabels = showsLabels
        self.onActivate = onActivate
        self.header = header()
        self.footer = footer()
    }

    public var body: some View {
        Sidebar(
            selection: selection, sections: [SidebarSection("rail", items: items)],
            presentation: .rail(showsLabels: showsLabels), onActivate: onActivate,
            header: { header }, footer: { footer }
        )
        .flex(0, shrink: 0).clipped()
    }
}

extension NavigationRail where Header == EmptyView, Footer == EmptyView {
    public init(
        selection: Binding<ID?>, items: [SidebarItem<ID>], showsLabels: Bool = true,
        onActivate: @escaping (ID) -> Void = { _ in }
    ) {
        self.init(
            selection: selection, items: items, showsLabels: showsLabels, onActivate: onActivate,
            header: { EmptyView() }, footer: { EmptyView() })
    }
}
