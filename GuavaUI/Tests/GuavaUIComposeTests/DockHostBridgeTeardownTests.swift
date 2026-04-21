import EngineKernel
import Foundation
import Testing
@testable import GuavaUICompose
@testable import GuavaUIRuntime

@Suite("Phase D4 polish: bridge ID round-trip + explicit unregister")
@MainActor
struct DockHostBridgeTeardownTests {

    @Test("Registration stamps a DockHostID retrievable from the node")
    func registrationStampsID() {
        let controller = DockController(root: .empty())
        let coordinator = DockHostCoordinator(controller: controller)
        let bridge = DockHostBridge(
            coordinator: coordinator,
            windowID: WindowID(42),
            originProvider: { (x: Float(0), y: Float(0)) },
            logicalSizeProvider: { (width: Float(100), height: Float(100)) }
        )
        let node = Node()
        node.registerDockHostBridge(bridge, hitRegistry: controller.hitRegistry)

        let id = node.dockHostID()
        #expect(id != nil)
        #expect(coordinator.hostCount_forTesting == 1)

        // Application calls unregister explicitly when the host window
        // is destroyed (see GuavaUIDemoDockMultiWindow.closeSatellite).
        coordinator.unregisterHost(id!)
        #expect(coordinator.hostCount_forTesting == 0)
    }

    @Test("Re-registering the same bridge is idempotent")
    func registrationIsIdempotent() {
        let controller = DockController(root: .empty())
        let coordinator = DockHostCoordinator(controller: controller)
        let bridge = DockHostBridge(
            coordinator: coordinator,
            windowID: WindowID(7),
            originProvider: { (x: Float(0), y: Float(0)) },
            logicalSizeProvider: { (width: Float(50), height: Float(50)) }
        )
        let node = Node()
        node.registerDockHostBridge(bridge, hitRegistry: controller.hitRegistry)
        node.registerDockHostBridge(bridge, hitRegistry: controller.hitRegistry)
        node.registerDockHostBridge(bridge, hitRegistry: controller.hitRegistry)
        #expect(coordinator.hostCount_forTesting == 1)
    }
}

extension DockHostCoordinator {
    var hostCount_forTesting: Int { hostsSnapshot_forTesting.count }
}

