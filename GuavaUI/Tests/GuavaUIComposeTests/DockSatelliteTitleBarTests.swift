import CoreGraphics
import EngineKernel
import Foundation
import Testing
@testable import GuavaUICompose
@testable import GuavaUIRuntime

/// Phase D6 — `_DockSatelliteTitleBar` lets a satellite (floating) window
/// be redocked back into the main host via title-bar drag.
@Suite("Phase D6 satellite title-bar redock", .serialized)
@MainActor
struct DockSatelliteTitleBarTests: GuavaUIComposeSerializedSuite {

    private func makeContent() -> DockContentResolver {
        return { key in AnyView(Text("k:\(key)")) }
    }

    private func findTitleBar(_ root: Node) -> Node? {
        var found: Node?
        func walk(_ n: Node) {
            guard found == nil else { return }
            // The title bar primitive sets isHitTestable + cursor pointer +
            // a fixed height of `DOCK_SATELLITE_TITLEBAR_HEIGHT`. There is
            // exactly one such bar in a satellite mount.
            if n.isHitTestable, n.cursor == .pointer,
               abs(Float(n.frame.height) - DOCK_SATELLITE_TITLEBAR_HEIGHT) < 0.5 {
                found = n; return
            }
            for c in n.children { walk(c) }
        }
        walk(root)
        return found
    }

    /// Build: main host with one tab, satellite with one detached leaf.
    /// Returns (mainController, satelliteLeafID, mainBridge, satelliteBridge).
    private func makeCluster() -> (DockController, DockNodeID,
                                    DockHostBridge, DockHostBridge,
                                    DockHostCoordinator) {
        let mainTab = DockTab(userKey: "main", title: "Main")
        let satTab  = DockTab(userKey: "sat",  title: "Sat")
        let satLeaf = DockLayoutNode.tabs([satTab])
        let satID = satLeaf.id
        let controller = DockController(root: .tabs([mainTab]))
        controller.replace(root: .tabs([mainTab]),
                           satellites: [satID: satLeaf],
                           satelliteOrder: [satID])
        let coordinator = DockHostCoordinator(controller: controller)
        let mainBridge = DockHostBridge(
            coordinator: coordinator,
            windowID: WindowID(1),
            originProvider: { (x: Float(0), y: Float(0)) },
            logicalSizeProvider: { (width: Float(400), height: Float(300)) }
        )
        let satBridge = DockHostBridge(
            coordinator: coordinator,
            windowID: WindowID(2),
            satelliteFor: satID,
            originProvider: { (x: Float(800), y: Float(0)) },
            logicalSizeProvider: { (width: Float(300), height: Float(200)) }
        )
        return (controller, satID, mainBridge, satBridge, coordinator)
    }

    @Test("Title-bar drag past threshold starts a satellite-origin session")
    func dragStartsSatelliteSession() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let (controller, satID, _, satBridge, _) = makeCluster()

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockSatelliteView(controller: controller,
                                              leafID: satID,
                                              hostBridge: satBridge,
                                              content: makeContent()))
        graph.computeLayout(width: 300, height: 200)

        let bar = findTitleBar(tree.root!)
        #expect(bar != nil, "satellite must mount a title bar")
        guard let bar else { return }

        let pointer = registry.handlers(for: bar).pointer!
        let motion  = registry.handlers(for: bar).motion!
        _ = pointer(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1),
                    .down, .target)
        _ = motion(MouseMotionEvent(x: 50, y: 14, deltaX: 40, deltaY: 4),
                   .target)

        #expect(controller.dragSession.isActive)
        if case .satellite(let leafID) = controller.dragSession.origin {
            #expect(leafID == satID)
        } else {
            Issue.record("expected .satellite origin, got \(controller.dragSession.origin)")
        }
        #expect(controller.dragSession.tabID == nil,
                "satellite drags don't carry a single source tab")
    } }

    @Test("Right click on the title bar does not start a redock drag")
    func rightClickDoesNotStartDrag() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let (controller, satID, _, satBridge, _) = makeCluster()

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockSatelliteView(controller: controller,
                                              leafID: satID,
                                              hostBridge: satBridge,
                                              content: makeContent()))
        graph.computeLayout(width: 300, height: 200)

        let bar = findTitleBar(tree.root!)
        #expect(bar != nil, "satellite must mount a title bar")
        guard let bar else { return }

        let pointer = registry.handlers(for: bar).pointer!
        let motion  = registry.handlers(for: bar).motion!
        _ = pointer(MouseButtonEvent(button: .right, x: 10, y: 10, clicks: 1),
                    .down, .target)
        _ = motion(MouseMotionEvent(x: 50, y: 14, deltaX: 40, deltaY: 4),
                   .target)

        #expect(controller.dragSession.isActive == false)
        #expect(PointerCaptureHolder.current?.target !== bar)
    } }
}
