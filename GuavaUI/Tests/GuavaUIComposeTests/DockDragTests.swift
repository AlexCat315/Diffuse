import Testing
import CoreGraphics
import GuavaUIRuntime
import EngineKernel
@testable import GuavaUICompose

/// Phase D2 — drag activation, drop-zone hit resolution, and the resulting
/// `.move` operation applied to the controller.
@Suite("Phase D2 / Dock drag", .serialized)
struct DockDragTests: GuavaUIComposeSerializedSuite {

    private func makeContent() -> DockContentResolver {
        return { key in AnyView(Text("k:\(key)")) }
    }

    /// Locate every hit-testable node — these correspond to tab items and
    /// resize handles. Tab items always have `.cursor == .pointer`.
    private func findTabItems(_ root: Node) -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) {
            // The close-X subtree contains its own pointer-cursor node
            // (the inner Button). Stop descending at the marker so it
            // doesn't get counted as a tab item.
            if n.attachments[_DockTabCloseButtonHost.kCloseButtonMarker] != nil {
                return
            }
            if n.isHitTestable, n.cursor == .pointer {
                out.append(n)
            }
            for c in n.children { walk(c) }
        }
        walk(root)
        return out
    }

    @Test("Pointer down + small motion does NOT start a drag (click threshold)")
    func clickThresholdGuardsDrag() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "k", title: "K")
        let controller = DockController(root: .tabs([tab]))
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let items = findTabItems(tree.root!)
        #expect(items.count == 1)
        let tabNode = items[0]

        let pointer = registry.handlers(for: tabNode).pointer!
        let motion  = registry.handlers(for: tabNode).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1), .down, .target)
        // Move 2 px — under the 4 px threshold.
        _ = motion(MouseMotionEvent(x: 12, y: 11, deltaX: 2, deltaY: 1), .target)
        #expect(controller.dragSession.isActive == false)
    } }

    @Test("Crossing the threshold starts a drag session with source leaf metadata")
    func crossesThresholdStartsDrag() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "k", title: "K")
        let controller = DockController(root: .tabs([tab]))
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let tabNode = findTabItems(tree.root!)[0]
        let pointer = registry.handlers(for: tabNode).pointer!
        let motion  = registry.handlers(for: tabNode).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 30, y: 30, deltaX: 20, deltaY: 20), .target)

        #expect(controller.dragSession.isActive)
        #expect(controller.dragSession.tabID == tab.id)
        if case .tabs(let leafID, _, _) = controller.root {
            #expect(controller.dragSession.sourceLeafID == leafID)
        } else {
            Issue.record("expected tabs leaf at root")
        }
    } }

    @Test("Drop on right-edge of a sibling leaf splits horizontally")
    func dropRightEdgeSplits() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let controller = DockController(root:
            .hsplit(fraction: 0.5,
                    first: .tabs([a]),
                    second: .tabs([b]))
        )
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let items = findTabItems(tree.root!)
        // Two tabs total; pick tab A (leftmost on screen by frame).
        let tabA = items.min(by: { $0.frame.origin.x < $1.frame.origin.x })!
        let pointer = registry.handlers(for: tabA).pointer!
        let motion  = registry.handlers(for: tabA).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 30, y: 12, clicks: 1), .down, .target)
        // Drag past threshold to start.
        _ = motion(MouseMotionEvent(x: 50, y: 30, deltaX: 20, deltaY: 18), .target)
        // Move into the right edge of leaf B (right half of a 600-wide window).
        _ = motion(MouseMotionEvent(x: 580, y: 200, deltaX: 530, deltaY: 170), .target)
        #expect(controller.dragSession.dropHit?.edge == .right)

        _ = pointer(MouseButtonEvent(button: .left, x: 580, y: 200, clicks: 1), .up, .target)

        // After the drop tab A should sit in a new leaf to the right of leaf B.
        // Because removing tab A leaves the source leaf empty, the original
        // outer split collapses and the new split becomes the root.
        guard case .split(_, .horizontal, _, let lhs, let rhs) = controller.root,
              case .tabs(_, let lhsTabs, _) = lhs,
              case .tabs(_, let rhsTabs, _) = rhs else {
            Issue.record("expected horizontal split with two tab leaves, got \(controller.root)")
            return
        }
        #expect(lhsTabs.contains { $0.id == b.id })
        #expect(rhsTabs.contains { $0.id == a.id })
    } }

    @Test("First lift motion resolves the preview target immediately")
    func firstLiftMotionResolvesPreviewTarget() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let controller = DockController(root:
            .hsplit(fraction: 0.5,
                    first: .tabs([a]),
                    second: .tabs([b]))
        )
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let items = findTabItems(tree.root!)
        let tabA = items.min(by: { $0.frame.origin.x < $1.frame.origin.x })!
        let pointer = registry.handlers(for: tabA).pointer!
        let motion = registry.handlers(for: tabA).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 30, y: 12, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 580, y: 200, deltaX: 550, deltaY: 188), .target)

        #expect(controller.dragSession.isActive)
        #expect(controller.dragSession.intent == .detachOrSplit)
        #expect(controller.dragSession.hoverLeafID != nil)
        #expect(controller.dragSession.dropHit?.edge == .right)
    } }

    @Test("Drag session subscription mirrors motion version into bound state")
    func dragSessionSubscriptionMirrorsVersion() {
        let tab = DockTab(userKey: "a", title: "A")
        let controller = DockController(root: .tabs([tab]))
        var observedVersion: UInt64 = 0
        let binding = Binding<UInt64>(
            get: { observedVersion },
            set: { observedVersion = $0 }
        )

        let token = ControllerSubscription.acquire(session: controller.dragSession,
                                                   tag: ObjectIdentifier(controller),
                                                   bind: binding,
                                                   extraTag: "test")
        defer { controller.dragSession.unsubscribe(token) }

        guard case .tabs(let leafID, _, _) = controller.root else {
            Issue.record("expected tabs leaf at root")
            return
        }

        controller.dragSession.start(tabID: tab.id,
                                     sourceLeafID: leafID,
                                     ghost: DockDragSession.GhostInfo(title: tab.title),
                                     x: 12,
                                     y: 8,
                                     intent: .detachOrSplit)

        #expect(observedVersion == controller.dragSession.version)
    }

    @Test("Drop on the source leaf centre is a no-op (cancelled)")
    func dropOnSelfCentreIsNoOp() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "k", title: "K")
        let controller = DockController(root: .tabs([tab]))
        let initial = controller.root
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let tabNode = findTabItems(tree.root!)[0]
        let pointer = registry.handlers(for: tabNode).pointer!
        let motion  = registry.handlers(for: tabNode).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 30, y: 12, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 50, y: 30, deltaX: 20, deltaY: 18), .target)
        // Move to the centre of the leaf (300, 200 in a 600x400 window).
        _ = motion(MouseMotionEvent(x: 300, y: 200, deltaX: 250, deltaY: 170), .target)
        #expect(controller.dragSession.dropHit == nil)

        _ = pointer(MouseButtonEvent(button: .left, x: 300, y: 200, clicks: 1), .up, .target)
        #expect(controller.root == initial)
    } }

    @Test("DockHitRegistry resolves the smallest leaf containing the pointer")
    func hitRegistrySmallestLeaf() {
        let registry = DockHitRegistry()
        let outer = Node()
        let inner = Node()
        outer.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        inner.frame = CGRect(x: 50, y: 50, width: 60, height: 60)
        outer.addChild(inner)

        let outerID = DockNodeID()
        let innerID = DockNodeID()
        registry.register(nodeID: outerID, node: outer)
        registry.register(nodeID: innerID, node: inner)

        // (75, 75) is inside both — must return inner.
        let hit = registry.leafAt(x: 75, y: 75)
        #expect(hit?.id == innerID)
    }

    @Test("DragSession.resolveDropHit picks edges by 25% margin band")
    func resolveDropEdgeBands() {
        let registry = DockHitRegistry()
        let n = Node()
        n.frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let id = DockNodeID()
        registry.register(nodeID: id, node: n)

        // 25% of min(400, 400) capped at 64 → band = 64.
        let leftHit = DockDragSession.resolveDropHit(x: 10, y: 200, sourceLeafID: nil, registry: registry)
        #expect(leftHit?.edge == .left)
        let rightHit = DockDragSession.resolveDropHit(x: 390, y: 200, sourceLeafID: nil, registry: registry)
        #expect(rightHit?.edge == .right)
        let topHit = DockDragSession.resolveDropHit(x: 200, y: 10, sourceLeafID: nil, registry: registry)
        #expect(topHit?.edge == .top)
        let bottomHit = DockDragSession.resolveDropHit(x: 200, y: 390, sourceLeafID: nil, registry: registry)
        #expect(bottomHit?.edge == .bottom)
        let centerHit = DockDragSession.resolveDropHit(x: 200, y: 200, sourceLeafID: nil, registry: registry)
        #expect(centerHit?.edge == .center)
    }

    @Test("DragSession.resolveDropHit snaps to guide-tile hotspots before edge bands")
    func resolveDropGuideHotspots() {
        let registry = DockHitRegistry()
        let n = Node()
        n.frame = CGRect(x: 0, y: 0, width: 220, height: 160)
        let id = DockNodeID()
        registry.register(nodeID: id, node: n)

        let tiles = makeDockDropGuideTiles(in: UIRect(x: 0, y: 0, width: 220, height: 160))
        #expect(tiles.count == 5)

        for tile in tiles {
            let px = tile.buttonRect.x + tile.buttonRect.width * 0.5
            let py = tile.buttonRect.y + tile.buttonRect.height * 0.5
            let hit = DockDragSession.resolveDropHit(x: px, y: py, sourceLeafID: nil, registry: registry)
            #expect(hit?.edge == tile.edge)
        }
    }

    @Test("Source leaf centre guide remains a no-op")
    func sourceLeafCenterGuideNoop() {
        let registry = DockHitRegistry()
        let n = Node()
        n.frame = CGRect(x: 0, y: 0, width: 220, height: 160)
        let id = DockNodeID()
        registry.register(nodeID: id, node: n)

        let centerTile = makeDockDropGuideTiles(in: UIRect(x: 0, y: 0, width: 220, height: 160))
            .first(where: { $0.edge == .center })
        #expect(centerTile != nil)
        guard let centerTile else { return }

        let px = centerTile.buttonRect.x + centerTile.buttonRect.width * 0.5
        let py = centerTile.buttonRect.y + centerTile.buttonRect.height * 0.5
        let hit = DockDragSession.resolveDropHit(x: px, y: py, sourceLeafID: id, registry: registry)
        #expect(hit == nil)
    }
}
