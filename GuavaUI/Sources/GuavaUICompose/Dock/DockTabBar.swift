import GuavaUIRuntime

/// Renders one tabs leaf: a tab strip followed by the active tab's content.
/// Wrapped in a primitive host so the leaf can register with the controller's
/// hit registry (for drag drop-zone resolution) and host the drop indicator
/// overlay without an extra Compose-side wrapper view.
struct _DockTabsLeaf: View {
    let nodeID: DockNodeID
    let tabs: [DockTab]
    let activeTabID: DockTabID?
    let controller: DockController
    let content: DockContentResolver

    var body: some View {
        _DockTabsLeafHost(nodeID: nodeID,
                          tabs: tabs,
                          activeTabID: activeTabID,
                          controller: controller,
                          content: content)
    }
}

struct _DockTabsLeafHost: _PrimitiveView {
    let nodeID: DockNodeID
    let tabs: [DockTab]
    let activeTabID: DockTabID?
    let controller: DockController
    let content: DockContentResolver

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = false
        return n
    }

    func _updateNode(_ node: Node) {
        let appearance = resolveDockAppearance(on: node)
        node.backgroundColor = appearance.leafBackground
        controller.hitRegistry.register(nodeID: nodeID, node: node)
        installDropOverlay(node: node, leafID: nodeID, controller: controller)
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        l.flexDirection = .column
        l.alignItems = .stretch
        return l
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.flexDirection = .column
        layout.alignItems = .stretch
    }

    func _children(for node: Node) -> [any View] {
        let strip = _DockTabBar(nodeID: nodeID,
                                tabs: tabs,
                                activeTabID: activeTabID,
                                controller: controller)
        let body = _DockLeafContent(activeTab: tabs.first(where: { $0.id == activeTabID }),
                                    content: content)
            .flex()
        return [strip, body]
    }
}

/// Tab strip: row of `_DockTabBarItem`s plus a trailing `Spacer`.
struct _DockTabBar: View {
    let nodeID: DockNodeID
    let tabs: [DockTab]
    let activeTabID: DockTabID?
    let controller: DockController

    var body: some View {
        _DockTabBarHost(nodeID: nodeID,
                        tabs: tabs,
                        activeTabID: activeTabID,
                        controller: controller)
    }
}

struct _DockTabBarHost: _PrimitiveView {
    let nodeID: DockNodeID
    let tabs: [DockTab]
    let activeTabID: DockTabID?
    let controller: DockController

    func _makeNode() -> Node { Node() }

    func _updateNode(_ node: Node) {
        let appearance = resolveDockAppearance(on: node)
        node.backgroundColor = appearance.tabBarBackground
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        l.flexDirection = .row
        l.alignItems = .stretch
        l.height = 32
        return l
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.flexDirection = .row
        layout.alignItems = .stretch
        layout.height = 32
    }

    func _children(for node: Node) -> [any View] {
        var children: [any View] = tabs.map { tab in
            _DockTabBarItem(tab: tab,
                            sourceLeafID: nodeID,
                            isActive: tab.id == activeTabID,
                            controller: controller)
        }
        children.append(Spacer())
        return children
    }
}

/// One tab in the strip. A primitive that handles both click-to-activate and
/// drag-to-move. We don't reuse `Button` because `Button` only exposes a
/// click action — drag needs the motion stream and pointer capture.
struct _DockTabBarItem: View {
    let tab: DockTab
    let sourceLeafID: DockNodeID
    let isActive: Bool
    let controller: DockController

    var body: some View {
        _DockTabBarItemHost(tab: tab,
                            sourceLeafID: sourceLeafID,
                            isActive: isActive,
                            controller: controller)
    }
}

/// Pointer must travel this many pixels (in any direction) past the press
/// point before a click upgrades to a drag.
private let DOCK_DRAG_THRESHOLD: Float = 4

struct _DockTabBarItemHost: _PrimitiveView {
    let tab: DockTab
    let sourceLeafID: DockNodeID
    let isActive: Bool
    let controller: DockController

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.cursor = .pointer
        return n
    }

    func _updateNode(_ node: Node) {
        let appearance = resolveDockAppearance(on: node)
        if isActive, let bg = appearance.tabActiveBackground {
            node.backgroundColor = bg
        } else {
            node.backgroundColor = nil
        }

        // Per-tab interaction state lives in `attachments` so it survives
        // recompose. Track the press-down origin so motion can decide when
        // to upgrade to a drag.
        let stateKey = "__dock_tab_state"

        guard let registry = InteractionRegistryHolder.current else { return }

        let snapshot = self
        // The bridge is resolved lazily inside the motion/up closures because
        // primitive `_updateNode` runs before this node is attached to its
        // parent — the parent-chain walk would always return `nil` here.

        registry.setPointer(node) { event, phase, _ in
            switch phase {
            case .down:
                node.attachments[stateKey] = TabPressState(downX: event.x,
                                                           downY: event.y,
                                                           didDrag: false)
                PointerCaptureHolder.current?.acquire(node)
                return .handled

            case .up:
                let state = (node.attachments[stateKey] as? TabPressState)
                    ?? TabPressState(downX: 0, downY: 0, didDrag: false)
                node.attachments[stateKey] = nil
                PointerCaptureHolder.current?.release()

                let session = snapshot.controller.dragSession
                if state.didDrag, session.isActive {
                    session.end(commit: true)
                } else {
                    if !snapshot.isActive {
                        snapshot.controller.apply(.setActive(node: snapshot.sourceLeafID,
                                                             tab: snapshot.tab.id))
                    }
                }
                return .handled
            }
        }

        registry.setMotion(node) { event, _ in
            guard PointerCaptureHolder.current?.target === node else {
                return .ignored
            }
            var state = (node.attachments[stateKey] as? TabPressState)
                ?? TabPressState(downX: event.x, downY: event.y, didDrag: false)
            let dx = event.x - state.downX
            let dy = event.y - state.downY
            let session = snapshot.controller.dragSession
            let bridge = node.compositionValue(of: DockHostBridgeLocal)
            if !state.didDrag {
                if abs(dx) > DOCK_DRAG_THRESHOLD || abs(dy) > DOCK_DRAG_THRESHOLD {
                    state.didDrag = true
                    if let bridge {
                        // Seed the cross-window drag with the global pointer
                        // derived from the host's window origin.
                        let originX = bridge.originProvider()?.x ?? 0
                        let originY = bridge.originProvider()?.y ?? 0
                        session.start(tabID: snapshot.tab.id,
                                      sourceLeafID: snapshot.sourceLeafID,
                                      ghost: DockDragSession.GhostInfo(title: snapshot.tab.title),
                                      x: event.x, y: event.y,
                                      globalX: originX + event.x,
                                      globalY: originY + event.y,
                                      origin: .mainTreeTab)
                    } else {
                        session.start(tabID: snapshot.tab.id,
                                      sourceLeafID: snapshot.sourceLeafID,
                                      ghost: DockDragSession.GhostInfo(title: snapshot.tab.title),
                                      x: event.x, y: event.y)
                    }
                }
            } else {
                if let bridge {
                    let originX = bridge.originProvider()?.x ?? 0
                    let originY = bridge.originProvider()?.y ?? 0
                    MainActor.assumeIsolated {
                        session.updatePointerCrossWindow(
                            currentWindowID: bridge.windowID,
                            windowLocal: (event.x, event.y),
                            global: (originX + event.x, originY + event.y),
                            coordinator: bridge.coordinator
                        )
                    }
                } else {
                    session.updatePointer(x: event.x, y: event.y,
                                          registry: snapshot.controller.hitRegistry)
                }
            }
            node.attachments[stateKey] = state
            return .handled
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        l.flexDirection = .column
        l.alignItems = .stretch
        return l
    }

    func _children(for node: Node) -> [any View] {
        let appearance = resolveDockAppearance(on: node)
        let label = Text(tab.title)
            .font(.bodyStrong)
            .foregroundColor(isActive ? .onSurface : .onSurfaceMuted)
            .padding(horizontal: appearance.tabHorizontalPadding,
                     vertical: 8)

        let underline: any View
        if isActive {
            underline = Box(direction: .row, alignItems: .stretch) { EmptyView() }
                .frame(height: appearance.tabActiveAccentBarHeight)
                .background(.accent)
        } else {
            underline = Box(direction: .row, alignItems: .stretch) { EmptyView() }
                .frame(height: appearance.tabActiveAccentBarHeight)
        }

        return [label, underline]
    }
}

struct TabPressState {
    var downX: Float
    var downY: Float
    var didDrag: Bool
}

/// Wrapper around the active tab's resolved view so the tabs leaf can read
/// it through a normal child slot. Falls back to a transparent filler when
/// no tab is active (state between `closeTab` and recompose).
struct _DockLeafContent: View {
    let activeTab: DockTab?
    let content: DockContentResolver

    var body: some View {
        if let tab = activeTab {
            content(tab.userKey)
        } else {
            Box(direction: .column, alignItems: .stretch) { EmptyView() }
        }
    }
}
