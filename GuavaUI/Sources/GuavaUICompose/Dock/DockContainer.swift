import GuavaUIRuntime

/// Resolves a `DockTab.userKey` to the View that renders that tab's content.
/// Provided as a closure to `DockContainer` at the call site so the dock
/// model never holds a `View` reference.
public typealias DockContentResolver = (String) -> AnyView

/// IDE-style multi-tab / split-pane container backed by a `DockController`.
///
/// ```swift
/// let dock = DockController(root: .hsplit(
///     fraction: 0.3,
///     first:  .tabs([DockTab(userKey: "explorer", title: "Explorer")]),
///     second: .tabs([DockTab(userKey: "console",  title: "Console")])
/// ))
///
/// DockContainer(controller: dock) { key in
///     switch key {
///     case "explorer": ExplorerPanel()
///     case "console":  ConsolePanel()
///     default:         EmptyView()
///     }
/// }
/// ```
///
/// The view subscribes to `controller`'s mutations and recomposes whenever
/// the layout tree changes (drag, resize, tab switch). Multiple containers
/// may share one controller — each maintains its own subscription.
public struct DockContainer: View {
    public let controller: DockController
    public let content: DockContentResolver
    public let hostBridge: DockHostBridge?
    public let horizontalInset: Float

    public init(controller: DockController,
                hostBridge: DockHostBridge? = nil,
            horizontalInset: Float = 8,
                @ViewBuilder content: @escaping () -> AnyView) {
        self.controller = controller
        self.hostBridge = hostBridge
        self.horizontalInset = max(0, horizontalInset)
        self.content = { _ in content() }
    }

    public init(controller: DockController,
                hostBridge: DockHostBridge? = nil,
            horizontalInset: Float = 8,
                content: @escaping DockContentResolver) {
        self.controller = controller
        self.hostBridge = hostBridge
        self.horizontalInset = max(0, horizontalInset)
        self.content = content
    }

    public var body: some View {
        _StatefulDockContainer(controller: controller,
                               hostBridge: hostBridge,
                               content: content)
            .padding(horizontal: horizontalInset, vertical: 0)
    }
}

// MARK: - Subscription wrapper

/// Owns the `@State` cell that records the controller's last-seen `version`.
/// Subscribing in `body` re-registers a closure on every recompose; the
/// closure captures the binding (reference semantics through `StateStorage`)
/// so the latest invocation wins without leaking state across recomposes.
struct _StatefulDockContainer: View {
    let controller: DockController
    let hostBridge: DockHostBridge?
    let content: DockContentResolver

    @State private var version: UInt64 = 0

    var body: some View {
        // Register dependency on `version` so a controller-driven write to
        // the binding invalidates this scope.
        let _ = version

        let bind = $version
        let tag = ObjectIdentifier(controller)
        let token = ControllerSubscription.acquire(controller: controller,
                                                   tag: tag,
                                                   bind: bind)
        let dragToken = ControllerSubscription.acquire(session: controller.dragSession,
                                                       tag: tag,
                                                       bind: bind,
                                                       extraTag: "drag-session")
        // Hold the token across recomposes via Node attachments? Not needed —
        // ControllerSubscription dedupes by tag so re-runs are idempotent and
        // we never accumulate handlers.
        _ = token
        _ = dragToken

        return _DockContainerRoot(controller: controller, hostBridge: hostBridge) {
            if controller.minimizedLeaves.isEmpty {
                _DockNodeView(node: controller.root,
                              controller: controller,
                              content: content)
                    .flex()
            } else {
                _DockContainerFrame(controller: controller) {
                    _DockNodeView(node: controller.root,
                                  controller: controller,
                                  content: content)
                        .flex()
                }
            }
        }
    }
}

/// Outermost host of a `DockContainer`. Owns the ghost overlay slot (so
/// the drag preview paints above all leaf content) without participating
/// in layout — a transparent column that grows to fill its parent.
struct _DockContainerRoot<Content: View>: _PrimitiveView {
    let controller: DockController
    let hostBridge: DockHostBridge?
    let content: Content

    init(controller: DockController,
         hostBridge: DockHostBridge?,
         @ViewBuilder content: () -> Content) {
        self.controller = controller
        self.hostBridge = hostBridge
        self.content = content()
    }

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = false
        return n
    }

    func _updateNode(_ node: Node) {
        installDragGhostOverlay(node: node,
                                controller: controller,
                                rootNodeID: controller.root.id)
        let registry = hostBridge?.hitRegistry ?? controller.hitRegistry
        registry.registerRoot(nodeID: controller.root.id, node: node)
        // Always (re-)publish the bridge so descendants reading
        // `DockHostBridgeLocal` see the latest value, even on recompose. The
        // bridge is optional — publishing nil is also valid.
        node.setCompositionValue(DockHostBridgeLocal, hostBridge)
        node.setCompositionValue(DockHitRegistryLocal, hostBridge?.hitRegistry)
        node.setCompositionValue(DockRootDropTargetIDLocal, controller.root.id)
        if let bridge = hostBridge {
            MainActor.assumeIsolated {
                node.registerDockHostBridge(bridge)
            }
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        l.flexDirection = .column
        l.alignItems = .stretch
        l.flexGrow = 1
        return l
    }

    var _children: [any View] { [content] }
}

struct _DockContainerFrame<Content: View>: View {
    let controller: DockController
    let content: Content

    init(controller: DockController,
         @ViewBuilder content: () -> Content) {
        self.controller = controller
        self.content = content()
    }

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Box(direction: .row, alignItems: .stretch, spacing: 0) {
                _DockMinimizedRail(edge: .left, controller: controller)
                content.flex()
                _DockMinimizedRail(edge: .right, controller: controller)
            }
            .flex()
            _DockMinimizedRail(edge: .bottom, controller: controller)
        }
        .flex()
    }
}

struct _DockMinimizedRail: _PrimitiveView {
    let edge: DockMinimizedEdge
    let controller: DockController

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = false
        return n
    }

    func _updateNode(_ node: Node) {
        node.animatableSet(\.backgroundColor,
                           to: items().isEmpty ? nil : node.theme.colors.surfaceVariant)
    }

    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }

    func _updateLayout(_ layout: LayoutNode) {
        let hasItems = !items().isEmpty
        switch edge {
        case .left, .right:
            layout.flexDirection = .column
            layout.alignItems = .center
            layout.setGap(4, gutter: .all)
            layout.width = hasItems ? 36 : 0
            layout.flexShrink = 0
        case .bottom:
            layout.flexDirection = .row
            layout.alignItems = .center
            layout.setGap(6, gutter: .all)
            layout.height = hasItems ? 36 : 0
            layout.flexShrink = 0
        }
    }

    func _children(for node: Node) -> [any View] {
        items().map { id, leaf in
            let title = railTitle(for: leaf.node, compact: edge != .bottom)
            let tooltip = railTitle(for: leaf.node, compact: false)
            let button = Button(title, tooltip: tooltip) {
                controller.apply(.restoreMinimizedLeaf(id))
            }
            .buttonStyle(.ghost)
            switch edge {
            case .left, .right:
                return button.frame(width: 28, height: 28) as any View
            case .bottom:
                return button as any View
            }
        }
    }

    private func items() -> [(DockNodeID, DockMinimizedLeaf)] {
        controller.minimizedOrder.compactMap { id in
            guard let leaf = controller.minimizedLeaves[id], leaf.edge == edge else { return nil }
            return (id, leaf)
        }
    }

    private func railTitle(for node: DockLayoutNode, compact: Bool) -> String {
        let title: String
        switch node {
        case .tabs(_, let tabs, let active):
            title = active.flatMap { activeID in
                tabs.first(where: { $0.id == activeID })?.title
            } ?? tabs.first?.title ?? "Panel"
        case .empty:
            title = "Panel"
        case .split:
            title = "Group"
        }
        guard compact else { return title }
        return title.first.map { String($0).uppercased() } ?? "P"
    }
}

/// Process-wide registry that gives each `(controller, container-instance)`
/// pair exactly one subscription, replacing the handler on every recompose
/// so the latest binding closure wins. Detaching is currently best-effort —
/// long-lived containers are the only stable case (D5 will tighten this).
enum ControllerSubscription {
    nonisolated(unsafe) private static var tokens: [Key: DockController.SubscriptionToken] = [:]
    nonisolated(unsafe) private static var dragTokens: [Key: UInt64] = [:]

    private struct Key: Hashable {
        let controllerID: ObjectIdentifier
        let tag: ObjectIdentifier
        let extraTag: String
    }

    static func acquire(controller: DockController,
                        tag: ObjectIdentifier,
                        bind: Binding<UInt64>,
                        extraTag: String = "") -> DockController.SubscriptionToken {
        let key = Key(controllerID: ObjectIdentifier(controller),
                      tag: tag,
                      extraTag: extraTag)
        if let existing = tokens[key] {
            controller.unsubscribe(existing)
        }
        let token = controller.subscribe { c in
            if bind.wrappedValue != c.version {
                bind.wrappedValue = c.version
            }
        }
        tokens[key] = token
        return token
    }

    static func acquire(session: DockDragSession,
                        tag: ObjectIdentifier,
                        bind: Binding<UInt64>,
                        extraTag: String = "") -> UInt64 {
        let key = Key(controllerID: ObjectIdentifier(session),
                      tag: tag,
                      extraTag: extraTag)
        if let existing = dragTokens[key] {
            session.unsubscribe(existing)
        }
        let token = session.subscribe {
            if bind.wrappedValue != session.version {
                bind.wrappedValue = session.version
            }
        }
        dragTokens[key] = token
        return token
    }
}

// MARK: - Recursive layout view

/// Walks one node of the layout tree and dispatches to the matching view.
/// Returns `AnyView` because the cases produce structurally different bodies.
struct _DockNodeView: View {
    let node: DockLayoutNode
    let controller: DockController
    let content: DockContentResolver

    var body: some View {
        switch node {
        case .empty(let id):
            return AnyView(_DockEmptyLeaf(nodeID: id, controller: controller))

        case .tabs(let id, let tabs, let active):
            return AnyView(_DockTabsLeaf(nodeID: id,
                                         tabs: tabs,
                                         activeTabID: active,
                                         controller: controller,
                                         content: content))

        case .split(let id, let axis, let frac, let first, let second):
            return AnyView(_DockSplit(splitID: id,
                                      axis: axis,
                                      fraction: frac,
                                      first: first,
                                      second: second,
                                      controller: controller,
                                      content: content))
        }
    }
}

// MARK: - Empty leaf

struct _DockEmptyLeaf: View {
    let nodeID: DockNodeID
    let controller: DockController

    var body: some View {
        _DockEmptyLeafHost(nodeID: nodeID, controller: controller)
    }
}

struct _DockEmptyLeafHost: _PrimitiveView {
    let nodeID: DockNodeID
    let controller: DockController

    func _makeNode() -> Node {
        let n = Node()
        return n
    }

    func _updateNode(_ node: Node) {
        let appearance = resolveDockAppearance(on: node)
        node.animatableSet(\.backgroundColor, to: appearance.emptyLeafBackground)
        installDropOverlay(node: node, leafID: nodeID, controller: controller)
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        l.flexGrow = 1
        return l
    }

    func _children(for node: Node) -> [any View] {
        let registry = resolveDockHitRegistry(on: node, fallback: controller.hitRegistry)
        registry.register(nodeID: nodeID, node: node)
        return []
    }
}

// MARK: - Helpers

@inline(__always)
func resolveDockAppearance(on node: Node) -> DockAppearance {
    let style = node.compositionValue(of: DockStyleEnvironment.key)
    return style.resolve(DockStyleConfiguration(theme: node.theme))
}
