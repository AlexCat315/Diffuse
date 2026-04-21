import EngineKernel
import Foundation
import Testing
@testable import GuavaUICompose
@testable import GuavaUIRuntime

@Suite("Phase D4 DockHostCoordinator")
@MainActor
struct DockHostCoordinatorTests {

    /// Build a controller with two leaves side by side, plus a detached
    /// satellite for the right-hand leaf. Returns enough handles for the
    /// caller to register hosts.
    private func makeFixture()
    -> (controller: DockController,
        coordinator: DockHostCoordinator,
        mainLeafID: DockNodeID,
        satelliteLeafID: DockNodeID) {
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let leafAID = leafA.id
        let leafBID = leafB.id
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))
        let coordinator = DockHostCoordinator(controller: controller)
        controller.apply(.detach(leafID: leafBID))
        return (controller, coordinator, leafAID, leafBID)
    }

    /// Stand up a hit registry with one leaf rectangle. Uses a real `Node`
    /// because `DockHitRegistry.leafAt` walks the parent chain — here the
    /// node has no parent so its frame doubles as the absolute frame.
    private func makeRegistry(leafID: DockNodeID,
                              x: CGFloat, y: CGFloat,
                              w: CGFloat, h: CGFloat) -> (DockHitRegistry, Node) {
        let node = Node()
        node.frame = CGRect(x: x, y: y, width: w, height: h)
        let registry = DockHitRegistry()
        registry.register(nodeID: leafID, node: node)
        return (registry, node)
    }

    @Test("Spawn callback fires once per detached leaf")
    func spawnCallbackFiresOnDetach() {
        let (controller, coordinator, _, satelliteLeafID) = makeFixture()
        // The fixture already detached before we could install the hook,
        // so set up a fresh detach to observe the callback.
        let tabC = DockTab(userKey: "c", title: "C")
        let leafC = DockLayoutNode.tabs([tabC])
        let leafCID = leafC.id
        controller.replace(root: .hsplit(first: controller.root, second: leafC))

        var spawnedIDs: [DockNodeID] = []
        coordinator.onSpawnSatellite = { id, _, _ in spawnedIDs.append(id) }

        controller.apply(.detach(leafID: leafCID))
        #expect(spawnedIDs == [leafCID])
        _ = satelliteLeafID
    }

    @Test("Closing a satellite from the model fires onCloseSatelliteWindow")
    func closeFiresWindowCallback() {
        let (controller, coordinator, _, satelliteLeafID) = makeFixture()
        var closedIDs: [DockNodeID] = []
        coordinator.onCloseSatelliteWindow = { id in closedIDs.append(id) }
        controller.apply(.closeSatellite(satelliteLeafID))
        #expect(closedIDs == [satelliteLeafID])
    }

    @Test("Resolving a global pointer routes to the right host's leaf")
    func resolveCrossWindow() {
        let (_, coordinator, mainLeafID, satelliteLeafID) = makeFixture()

        // Main window at desktop (0, 0), 800x600, with leaf A filling it.
        let (mainRegistry, mainNode) = makeRegistry(leafID: mainLeafID,
                                                    x: 0, y: 0,
                                                    w: 800, h: 600)
        let mainWindowID = WindowID(1)
        coordinator.registerMainHost(
            windowID: mainWindowID,
            hitRegistry: mainRegistry,
            originProvider: { (x: Float(0), y: Float(0)) },
            logicalSizeProvider: { (width: Float(800), height: Float(600)) }
        )

        // Satellite window at desktop (1000, 100), 400x300, hosting the
        // detached leaf.
        let (satRegistry, satNode) = makeRegistry(leafID: satelliteLeafID,
                                                  x: 0, y: 0,
                                                  w: 400, h: 300)
        let satWindowID = WindowID(2)
        coordinator.registerSatelliteHost(
            leafID: satelliteLeafID,
            windowID: satWindowID,
            hitRegistry: satRegistry,
            originProvider: { (x: Float(1000), y: Float(100)) },
            logicalSizeProvider: { (width: Float(400), height: Float(300)) }
        )

        // A pointer at desktop (1100, 150) should map onto the satellite.
        guard let satResolved = coordinator.resolveGlobalDropHit(
            globalX: 1100, globalY: 150, sourceLeafID: nil) else {
            Issue.record("expected a hit inside the satellite window"); return
        }
        #expect(satResolved.host.windowID == satWindowID)
        #expect(satResolved.hit.leafID == satelliteLeafID)

        // A pointer at desktop (50, 50) should map onto the main window.
        guard let mainResolved = coordinator.resolveGlobalDropHit(
            globalX: 50, globalY: 50, sourceLeafID: nil) else {
            Issue.record("expected a hit inside the main window"); return
        }
        #expect(mainResolved.host.windowID == mainWindowID)
        #expect(mainResolved.hit.leafID == mainLeafID)

        // A pointer in dead space (between windows) should return nil.
        let dead = coordinator.resolveGlobalDropHit(
            globalX: 900, globalY: 50, sourceLeafID: nil)
        #expect(dead == nil)
        // Keep nodes alive past the assertions — the registry holds them
        // weakly so the test must own a strong reference.
        _ = mainNode
        _ = satNode
    }

    @Test("Drag session cross-window update commits a redock on release")
    func dragRedockCommit() {
        let (controller, coordinator, mainLeafID, satelliteLeafID) = makeFixture()

        let (mainRegistry, mainNode) = makeRegistry(leafID: mainLeafID,
                                                    x: 0, y: 0, w: 800, h: 600)
        coordinator.registerMainHost(
            windowID: WindowID(1),
            hitRegistry: mainRegistry,
            originProvider: { (x: Float(0), y: Float(0)) },
            logicalSizeProvider: { (width: Float(800), height: Float(600)) }
        )

        let satTab = controller.satellites[satelliteLeafID].flatMap { node -> DockTab? in
            if case .tabs(_, let tabs, _) = node { return tabs.first }
            return nil
        }
        guard let satTab else {
            Issue.record("satellite leaf should still hold its tab"); return
        }

        // Simulate the satellite window being dragged: source is the
        // satellite leaf itself.
        let session = controller.dragSession
        session.start(tabID: satTab.id,
                      sourceLeafID: satelliteLeafID,
                      ghost: DockDragSession.GhostInfo(title: satTab.title),
                      x: 0, y: 0,
                      globalX: 0, globalY: 0,
                      origin: .satellite(leafID: satelliteLeafID))

        // Pointer hovers near the right edge of the main leaf — a horizontal
        // split should result.
        session.updatePointerCrossWindow(
            currentWindowID: WindowID(2),
            windowLocal: (0, 0),
            global: (790, 300),
            coordinator: coordinator
        )
        #expect(session.dropHit?.leafID == mainLeafID)
        #expect(session.dropHit?.edge == .right)

        session.end(commit: true)
        // After redock, satellite should be gone and the root should be a
        // horizontal split with the main leaf on the left.
        #expect(controller.satellites.isEmpty)
        guard case .split(_, let axis, _, let first, _) = controller.root else {
            Issue.record("expected a split after redock"); return
        }
        #expect(axis == .horizontal)
        #expect(first.id == mainLeafID)
        _ = mainNode
    }

    @Test("Releasing outside every host triggers detach for a main-tree drag")
    func dragOutsideTriggersDetach() {
        let (controller, coordinator, mainLeafID, _) = makeFixture()
        // Add a second leaf so we have something to detach (the fixture
        // already collapsed root onto the main leaf).
        let extraTab = DockTab(userKey: "x", title: "X")
        let extraLeaf = DockLayoutNode.tabs([extraTab])
        let extraLeafID = extraLeaf.id
        controller.replace(root: .hsplit(first: controller.root, second: extraLeaf))

        let (registry, node) = makeRegistry(leafID: mainLeafID,
                                            x: 0, y: 0, w: 400, h: 600)
        coordinator.registerMainHost(
            windowID: WindowID(1),
            hitRegistry: registry,
            originProvider: { (x: Float(0), y: Float(0)) },
            logicalSizeProvider: { (width: Float(800), height: Float(600)) }
        )

        let session = controller.dragSession
        session.start(tabID: extraTab.id,
                      sourceLeafID: extraLeafID,
                      ghost: DockDragSession.GhostInfo(title: extraTab.title),
                      x: 500, y: 300,
                      globalX: 500, globalY: 300,
                      origin: .mainTreeTab)

        // Pointer somewhere in dead space far from the main host.
        session.updatePointerCrossWindow(
            currentWindowID: WindowID(1),
            windowLocal: (1500, 1500),
            global: (1500, 1500),
            coordinator: coordinator
        )
        #expect(session.isOutsideAllHosts == true)
        #expect(session.dropHit == nil)

        session.end(commit: true)
        // The extra leaf should now be detached as a satellite.
        #expect(controller.satellites[extraLeafID] != nil)
        _ = node
    }
}
