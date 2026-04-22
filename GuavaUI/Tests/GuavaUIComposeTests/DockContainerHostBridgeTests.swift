import EngineKernel
import Foundation
import Testing
@testable import GuavaUICompose
@testable import GuavaUIRuntime

@Suite("Phase D4 DockContainer host bridge", .serialized)
@MainActor
struct DockContainerHostBridgeTests: GuavaUIComposeSerializedSuite {

    @Test("DockContainer with a host bridge auto-registers a main host with the coordinator")
    func dockContainerAutoRegistersMainHost() { GlobalTestLock.locked {
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        let tab = DockTab(userKey: "main", title: "Main")
        let leaf = DockLayoutNode.tabs([tab])
        let leafID = leaf.id
        let controller = DockController(root: leaf)
        let coordinator = DockHostCoordinator(controller: controller)
        let bridge = DockHostBridge(
            coordinator: coordinator,
            windowID: WindowID(1),
            originProvider: { (x: Float(0), y: Float(0)) },
            logicalSizeProvider: { (width: Float(800), height: Float(600)) }
        )

        // Materialise the dock container into a real ViewGraph so the host
        // primitive's `_updateNode` runs and triggers the registration.
        let container = DockContainer(controller: controller, hostBridge: bridge) { _ in
            AnyView(EmptyView())
        }
        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)
        graph.install(root: container)
        graph.computeLayout(width: 800, height: 600)

        // Coordinator should now see the main host and resolve a global
        // pointer onto its leaf.
        guard let resolved = coordinator.resolveGlobalDropHit(
            globalX: 100, globalY: 100, sourceLeafID: nil) else {
            Issue.record("expected a hit through the registered host"); return
        }
        #expect(resolved.host.windowID == WindowID(1))
        #expect(resolved.hit.leafID == leafID)
        _ = graph
    } }

    @Test("DockSatelliteView with a host bridge registers as a satellite host")
    func dockSatelliteRegistersSatelliteHost() { GlobalTestLock.locked {
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let leafBID = leafB.id
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))
        let coordinator = DockHostCoordinator(controller: controller)
        controller.apply(.detach(leafID: leafBID))
        #expect(controller.satellites[leafBID] != nil)

        let bridge = DockHostBridge(
            coordinator: coordinator,
            windowID: WindowID(2),
            satelliteFor: leafBID,
            originProvider: { (x: Float(500), y: Float(200)) },
            logicalSizeProvider: { (width: Float(400), height: Float(300)) }
        )

        let view = DockSatelliteView(controller: controller,
                                     leafID: leafBID,
                                     hostBridge: bridge) { _ in
            AnyView(EmptyView())
        }
        let tree = NodeTree()
        let recomposer = Recomposer()
        let graph = ViewGraph(tree: tree, recomposer: recomposer)
        graph.install(root: view)
        graph.computeLayout(width: 400, height: 300)

        #expect(coordinator.satelliteWindowID(for: leafBID) == WindowID(2))
        _ = graph
    } }

    @Test("Mounted main and satellite views keep separate hit registries")
    func mountedViewsUseSeparateHitRegistries() { GlobalTestLock.locked {
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tabA = DockTab(userKey: "a", title: "A")
        let tabB = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([tabA])
        let leafB = DockLayoutNode.tabs([tabB])
        let leafAID = leafA.id
        let leafBID = leafB.id
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))
        let coordinator = DockHostCoordinator(controller: controller)
        controller.apply(.detach(leafID: leafBID))

        let mainBridge = DockHostBridge(
            coordinator: coordinator,
            windowID: WindowID(1),
            originProvider: { (x: Float(0), y: Float(0)) },
            logicalSizeProvider: { (width: Float(800), height: Float(600)) }
        )
        let satelliteBridge = DockHostBridge(
            coordinator: coordinator,
            windowID: WindowID(2),
            satelliteFor: leafBID,
            originProvider: { (x: Float(1000), y: Float(100)) },
            logicalSizeProvider: { (width: Float(400), height: Float(300)) }
        )

        let mainTree = NodeTree()
        let mainGraph = ViewGraph(tree: mainTree, recomposer: Recomposer())
        mainGraph.install(root: DockContainer(controller: controller,
                                              hostBridge: mainBridge) { _ in
            AnyView(EmptyView())
        })
        mainGraph.computeLayout(width: 800, height: 600)

        let satTree = NodeTree()
        let satGraph = ViewGraph(tree: satTree, recomposer: Recomposer())
        satGraph.install(root: DockSatelliteView(controller: controller,
                                                 leafID: leafBID,
                                                 hostBridge: satelliteBridge) { _ in
            AnyView(EmptyView())
        })
        satGraph.computeLayout(width: 400, height: 300)

        let mainHost = coordinator.host(for: WindowID(1))
        let satHost = coordinator.host(for: WindowID(2))
        #expect(mainHost != nil)
        #expect(satHost != nil)
        #expect(mainHost?.hitRegistry !== satHost?.hitRegistry)

        guard let mainResolved = coordinator.resolveGlobalDropHit(
            globalX: 100, globalY: 100, sourceLeafID: leafBID
        ) else {
            Issue.record("expected a hit inside the mounted main host")
            return
        }
        #expect(mainResolved.host.windowID == WindowID(1))
        #expect(mainResolved.hit.leafID == leafAID)

        _ = mainGraph
        _ = satGraph
    } }
}
