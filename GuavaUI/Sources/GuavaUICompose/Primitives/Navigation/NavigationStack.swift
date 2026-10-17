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
    @State private var lastRoutes: [Route]
    @State private var isAnimating = false

    public init(path: Binding<[Route]>,
                transitionDistance: Float = 32,
                @ViewBuilder root: @escaping () -> Root,
                @ViewBuilder destination: @escaping (Route) -> Destination) {
        self.path = path
        self.transitionDistance = transitionDistance.isFinite ? max(0, transitionDistance) : 32
        self.root = root
        self.destination = destination
        _lastCount = State(wrappedValue: path.wrappedValue.count)
        _lastRoutes = State(wrappedValue: path.wrappedValue)
    }

    private var routes: [Route] { path.wrappedValue }

    public var body: some View {
        ContainerSizeReader { size in
            ThemeReader { theme in
                let routes = self.routes
                let forward = routes.count >= lastCount
                ZStack(alignment: .topLeading) {
                    _NavigationPathWatcher(count: routes.count) { count in
                        guard count != lastCount else { return }
                        if isAnimating {
                            if path.wrappedValue != lastRoutes {
                                path.wrappedValue = lastRoutes
                            }
                            return
                        }
                        lastRoutes = path.wrappedValue
                        lastCount = count
                        isAnimating = true
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
                                  animateOnMount: index > 0, retainsContent: true,
                                  onVisibilitySettled: { visible in
            if visible, isAnimating { isAnimating = false }
        }) {
            _NavigationPageFocusHost(isTop: isTop,
                content: pageContent(route: route, theme: theme, width: width, height: height))
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


/// Marks a page title as the focus target for a NavigationStack push/pop.
/// The stack focuses it without a visible keyboard ring once the new page has
/// laid out; ordinary keyboard traversal continues from there.
public extension View {
    func navigationTitle(_ title: String) -> some View {
        accessibility {
            $0.role = .heading
            $0.label = title
            $0.identifier = "navigation.title"
        }
    }
}

private struct _NavigationPageFocusHost<Content: View>: _PrimitiveView {
    let isTop: Bool
    let content: Content

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.alignItems = .stretch
        return layout
    }

    func _updateNode(_ node: Node) {
        let wasTop = node.attachments["navigation.page.isTop"] as? Bool ?? false
        node.attachments["navigation.page.isTop"] = isTop
        if !isTop {
            node.attachments["navigation.page.titleFocused"] = false
            return
        }
        guard !wasTop else { return }
        node.layoutDidUpdate = { node in
            guard node.attachments["navigation.page.isTop"] as? Bool == true,
                  node.attachments["navigation.page.titleFocused"] as? Bool != true,
                  let title = findTitle(in: node),
                  let chain = FocusChainHolder.current else { return }
            node.attachments["navigation.page.titleFocused"] = true
            chain.focus(title, visible: false)
        }
    }

    private func findTitle(in node: Node) -> Node? {
        if node.accessibility?.identifier == "navigation.title" { return node }
        if node.accessibility?.role == .heading { return node }
        for child in node.children {
            if let found = findTitle(in: child) { return found }
        }
        return nil
    }

    var _children: [any View] { [content] }
}
