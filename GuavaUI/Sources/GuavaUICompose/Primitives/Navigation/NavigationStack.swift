import GuavaUIRuntime

/// Session-owned page stack. The caller owns `path`; pushing appends a route,
/// popping removes the last one, and a non-empty initial path restores a deep
/// link on the first frame.
///
/// The root and every route page stay mounted while they are in the path, so a
/// push keeps the root's drafts, scroll and local state. Only the top page is
/// interactive and painted; the incoming page slides from the trailing edge
/// with a fade, and the outgoing page slides to the leading edge. Popping
/// reveals the retained previous page with the reverse motion. Reduced motion
/// is handled by `AnimatedVisibility`.
///
/// Platform back (Android back / iOS edge) is a host concern: the host should
/// remove the last route. The component deliberately does not consume Escape;
/// overlays keep priority over page navigation.
public struct NavigationStack<Route: Hashable, Root: View, Destination: View>: View {
    public let path: Binding<[Route]>
    private let root: () -> Root
    private let destination: (Route) -> Destination
    /// Horizontal travel of the page transition in logical points.
    public let transitionDistance: Float

    @State private var lastCount: Int

    public init(path: Binding<[Route]>,
                transitionDistance: Float = 32,
                @ViewBuilder root: @escaping () -> Root,
                @ViewBuilder destination: @escaping (Route) -> Destination) {
        self.path = path
        self.transitionDistance = transitionDistance.isFinite ? max(0, transitionDistance) : 32
        self.root = root
        self.destination = destination
        _lastCount = State(wrappedValue: path.wrappedValue.count)
    }

    private var routes: [Route] { path.wrappedValue }

    public var body: some View {
        ContainerSizeReader { size in
            ThemeReader { theme in
                let routes = self.routes
                let forward = routes.count >= lastCount
                ZStack(alignment: .topLeading) {
                    _NavigationPathWatcher(count: routes.count) { count in
                        if lastCount != count { lastCount = count }
                    }
                    AnyView(page(route: nil, index: 0, isTop: routes.isEmpty,
                                 forward: forward, theme: theme,
                                 width: Float(size.width), height: Float(size.height)))
                    for (offset, route) in routes.enumerated() {
                        AnyView(page(route: route, index: offset + 1,
                                     isTop: offset == routes.count - 1, forward: forward,
                                     theme: theme, width: Float(size.width), height: Float(size.height)))
                    }
                }
            }
        }
    }

    private func page(route: Route?, index: Int, isTop: Bool, forward: Bool, theme: Theme,
                      width: Float, height: Float) -> some View {
        let transition = Transition.navigation(distance: transitionDistance, forward: forward)
        return AnimatedVisibility(isVisible: isTop, transition: transition,
                                  animateOnMount: index > 0, retainsContent: true) {
            pageContent(route: route, theme: theme, width: width, height: height)
        }
        .id(route.map { AnyHashable($0) } ?? AnyHashable("navigation.root"))
    }

    private func pageContent(route: Route?, theme: Theme, width: Float, height: Float) -> some View {
        let content: AnyView
        if let route {
            content = AnyView(destination(route))
        } else {
            content = AnyView(root())
        }
        return content
            .frame(width: .points(max(1, width)), height: .points(max(1, height)))
            .background(theme.colors.background)
    }
}

/// Calls back once per path-count change. The node has zero size and does not
/// participate in hit testing; its attachment stores the last observed count so
/// the first mount is not reported as a navigation.
private struct _NavigationPathWatcher: _PrimitiveView {
    let count: Int
    let onChange: (Int) -> Void

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.width = 0
        layout.height = 0
        return layout
    }

    func _updateNode(_ node: Node) {
        let previous = node.attachments["navigation.path.count"] as? Int
        node.attachments["navigation.path.count"] = count
        if let previous, previous != count { onChange(count) }
    }
}
