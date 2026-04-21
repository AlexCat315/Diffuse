import CoreGraphics
import GuavaUIRuntime

/// Drag handle that lets the user redock a satellite (floating) window
/// back into a main host. Behaviour:
///
/// 1. Press inside the bar → captures pointer.
/// 2. Motion past `DOCK_DRAG_THRESHOLD` upgrades to a drag and starts a
///    `DockDragSession` with `origin: .satellite(leafID)`.
/// 3. Subsequent motion calls `updatePointerCrossWindow` so the
///    coordinator can resolve drop hits in any window in the cluster.
/// 4. Release while hovering over a registered host's leaf → fires
///    `controller.apply(.redock(satelliteID: leafID, to: target))`.
///    Release outside any host → no-op (the satellite stays where it is).
///
/// Visual: short title row with the active tab's title. The host
/// application is expected to also expose a close affordance (the demo
/// uses the SDL window close button), so this bar is intentionally
/// minimal — it carries the redock interaction only.
struct _DockSatelliteTitleBar: _PrimitiveView {
    let controller: DockController
    let leafID: DockNodeID

    func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.cursor = .pointer
        return n
    }

    func _updateNode(_ node: Node) {
        let appearance = resolveDockAppearance(on: node)
        node.backgroundColor = appearance.tabBarBackground

        let stateKey = "__dock_satellite_titlebar_state"
        let snapshot = self
        guard let registry = InteractionRegistryHolder.current else { return }

        registry.setKey(node) { event, _ in
            if event.scancode == DOCK_KEY_SCANCODE_ESC {
                let session = snapshot.controller.dragSession
                if session.isActive {
                    PointerCaptureHolder.current?.release()
                    node.attachments[stateKey] = nil
                    session.cancel()
                    return .handled
                }
            }
            return .ignored
        }

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
            // Read the bridge lazily — see DockTabBar for why eager
            // reads inside `_updateNode` always return nil.
            let bridge = node.compositionValue(of: DockHostBridgeLocal)

            if !state.didDrag {
                if abs(dx) > DOCK_SATELLITE_DRAG_THRESHOLD
                    || abs(dy) > DOCK_SATELLITE_DRAG_THRESHOLD {
                    state.didDrag = true
                    let title = snapshot.dragGhostTitle()
                    if let bridge {
                        let originX = bridge.originProvider()?.x ?? 0
                        let originY = bridge.originProvider()?.y ?? 0
                        session.start(
                            tabID: nil,
                            sourceLeafID: snapshot.leafID,
                            ghost: DockDragSession.GhostInfo(title: title),
                            x: event.x, y: event.y,
                            globalX: originX + event.x,
                            globalY: originY + event.y,
                            origin: .satellite(leafID: snapshot.leafID)
                        )
                    } else {
                        session.start(
                            tabID: nil,
                            sourceLeafID: snapshot.leafID,
                            ghost: DockDragSession.GhostInfo(title: title),
                            x: event.x, y: event.y,
                            origin: .satellite(leafID: snapshot.leafID)
                        )
                    }
                }
            } else if let bridge {
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
            }
            node.attachments[stateKey] = state
            return .handled
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let l = LayoutNode()
        l.flexDirection = .row
        l.alignItems = .center
        l.height = DOCK_SATELLITE_TITLEBAR_HEIGHT
        return l
    }

    func _updateLayout(_ layout: LayoutNode) {
        layout.height = DOCK_SATELLITE_TITLEBAR_HEIGHT
    }

    func _children(for node: Node) -> [any View] {
        return [
            Text(dragGhostTitle())
                .font(.bodyStrong)
                .foregroundColor(.onSurfaceMuted)
                .padding(horizontal: 12, vertical: 6)
        ]
    }

    /// Best-effort title for the ghost / bar label: the active tab of the
    /// satellite leaf, falling back to the leaf's first tab, then a
    /// generic placeholder.
    fileprivate func dragGhostTitle() -> String {
        guard let leaf = controller.satellites[leafID] else { return "Window" }
        if case .tabs(_, let tabs, let activeID) = leaf {
            if let activeID, let active = tabs.first(where: { $0.id == activeID }) {
                return active.title
            }
            if let first = tabs.first { return first.title }
        }
        return "Window"
    }
}

/// Drag-activation distance for the satellite title bar (in points).
/// Slightly larger than the tab-strip threshold because a title-bar
/// click is more often "I just want focus" than "I want to drag".
let DOCK_SATELLITE_DRAG_THRESHOLD: Float = 6

/// Visual height of the satellite title bar, in points.
let DOCK_SATELLITE_TITLEBAR_HEIGHT: Float = 24

/// SDL3 scancode for the Escape key (`SDL_SCANCODE_ESCAPE`). Used by dock
/// drag handlers to recognise drag-cancel without having to import SDL.
let DOCK_KEY_SCANCODE_ESC: UInt32 = 41
