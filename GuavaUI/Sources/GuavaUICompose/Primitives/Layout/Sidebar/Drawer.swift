import GuavaUIRuntime

public struct NavigationDrawerOptions {
    public var dismissal = ModalDismissal()
    public var closesOnSelection = true
    public var allowsSwipeDismissal = true
    public var closeLabel = "Close navigation"
    public init() {}
}

/// Modal navigation, sharing Sidebar destinations and the standard modal lifecycle.
/// The application owns presentation and selection, so resizing never resets them.
public struct NavigationDrawer<ID: Hashable, Header: View, Footer: View>: View {
    private let title: String
    private let isPresented: Binding<Bool>
    private let selection: Binding<ID?>
    private let sections: [SidebarSection<ID>]
    private let options: NavigationDrawerOptions
    private let header: Header
    private let footer: Footer

    public init(
        _ title: String, isPresented: Binding<Bool>, selection: Binding<ID?>,
        sections: [SidebarSection<ID>], configure: (inout NavigationDrawerOptions) -> Void = { _ in },
        @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.isPresented = isPresented
        self.selection = selection
        self.sections = sections
        var options = NavigationDrawerOptions()
        configure(&options)
        self.options = options
        self.header = header()
        self.footer = footer()
    }

    public var body: some View {
        Modal(
            isPresented: isPresented,
            configure: {
                $0.geometry.placement = .leading
                $0.geometry.inset = 0
                $0.geometry.cornerRadius = 0
                $0.dismissal = options.dismissal
                $0.backdrop = .selection
            },
            fittingGeometry: { geometry, window in
                geometry.width = min(320, max(0, Float(window.width) - 56))
                geometry.height = Float(window.height)
            }
        ) {
            HorizontalSwipeHost(
                onSwipe: { direction in
                    if direction == .left { isPresented.wrappedValue = false }
                }, isEnabled: options.allowsSwipeDismissal && isPresented.wrappedValue
            ) {
                Sidebar(
                    selection: selection, sections: sections, minimumRowHeight: 44,
                    onActivate: { _ in
                        if options.closesOnSelection { isPresented.wrappedValue = false }
                    },
                    header: {
                        Box(direction: .column, alignItems: .stretch) {
                            Box(direction: .row, alignItems: .center, spacing: 8) {
                                Text(title).font(.bodyStrong).flex(1, shrink: 1).frame(minWidth: 0)
                                Button(icon: .resource(UIIcons.Action.x), tooltip: options.closeLabel) {
                                    isPresented.wrappedValue = false
                                }
                                .buttonStyle(.ghost).frame(minWidth: 44, minHeight: 44)
                                .accessibilityLabel(options.closeLabel).flex(0, shrink: 0)
                            }.padding(horizontal: 12, vertical: 8)
                            header
                        }
                    }, footer: { footer }
                ).flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
            }.accessibilityLabel(title)
        }
    }
}

extension NavigationDrawer where Header == EmptyView, Footer == EmptyView {
    public init(
        _ title: String, isPresented: Binding<Bool>, selection: Binding<ID?>,
        sections: [SidebarSection<ID>], configure: (inout NavigationDrawerOptions) -> Void = { _ in }
    ) {
        self.init(
            title, isPresented: isPresented, selection: selection, sections: sections, configure: configure,
            header: { EmptyView() }, footer: { EmptyView() })
    }
}
