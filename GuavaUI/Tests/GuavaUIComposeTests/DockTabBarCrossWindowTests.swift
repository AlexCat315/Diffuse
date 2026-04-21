import CoreGraphics
import EngineKernel
import Foundation
import Testing
@testable import GuavaUICompose
@testable import GuavaUIRuntime

/// Phase D4 — DockTabBar reads a `DockHostBridge` from the composition
/// chain and switches to the cross-window flow when one is published.
@Suite("Phase D4 DockTabBar cross-window", .serialized)
@MainActor
struct DockTabBarCrossWindowTests: GuavaUIComposeSerializedSuite {

    private func makeContent() -> DockContentResolver {
        return { key in AnyView(Text("k:\(key)")) }
    }

    private func findTabItems(_ root: Node) -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) {
            if n.isHitTestable, n.cursor == .pointer {
                out.append(n)
            }
            for c in n.children { walk(c) }
        }
        walk(root)
        return out
    }

    @Test("Bridge composition local resolves from a tab item")
    func bridgeResolvesFromTabItem() { GlobalTestLock.locked {
        let tab = DockTab(userKey: "k", title: "K")
        let controller = DockController(root: .tabs([tab]))
        let coordinator = DockHostCoordinator(controller: controller)
        let bridge = DockHostBridge(
            coordinator: coordinator,
            windowID: WindowID(1),
            originProvider: { (x: Float(200), y: Float(100)) },
            logicalSizeProvider: { (width: Float(600), height: Float(400)) }
        )

        InteractionRegistryHolder.current = InteractionRegistry()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller,
                                          hostBridge: bridge,
                                          content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let tabNode = findTabItems(tree.root!)[0]
        let resolved = tabNode.compositionValue(of: DockHostBridgeLocal)
        #expect(resolved != nil, "tab item should resolve the host bridge from its parent chain")
    } }

    @Test("Drag past threshold with a host bridge publishes the bridge's window origin")
    func crossWindowStartUsesBridgeOrigin() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "k", title: "K")
        let controller = DockController(root: .tabs([tab]))
        let coordinator = DockHostCoordinator(controller: controller)
        let bridge = DockHostBridge(
            coordinator: coordinator,
            windowID: WindowID(1),
            originProvider: { (x: Float(200), y: Float(100)) },
            logicalSizeProvider: { (width: Float(600), height: Float(400)) }
        )

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller,
                                          hostBridge: bridge,
                                          content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let tabNode = findTabItems(tree.root!)[0]
        let pointer = registry.handlers(for: tabNode).pointer!
        let motion  = registry.handlers(for: tabNode).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 30, y: 30, deltaX: 20, deltaY: 20), .target)

        #expect(controller.dragSession.isActive)
        #expect(controller.dragSession.globalPointerX == 230) // 200 + 30
        #expect(controller.dragSession.globalPointerY == 130) // 100 + 30
        if case .mainTreeTab = controller.dragSession.origin {
            // ok
        } else {
            Issue.record("expected mainTreeTab origin")
        }
    } }

    @Test("Pointer drifting outside all hosts marks the session for detach")
    func crossWindowOutsideHostMarksDetach() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let tab = DockTab(userKey: "k", title: "K")
        let controller = DockController(root: .tabs([tab]))
        let coordinator = DockHostCoordinator(controller: controller)
        let bridge = DockHostBridge(
            coordinator: coordinator,
            windowID: WindowID(1),
            originProvider: { (x: Float(0), y: Float(0)) },
            logicalSizeProvider: { (width: Float(600), height: Float(400)) }
        )

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller,
                                          hostBridge: bridge,
                                          content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let tabNode = findTabItems(tree.root!)[0]
        let pointer = registry.handlers(for: tabNode).pointer!
        let motion  = registry.handlers(for: tabNode).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 30, y: 30, deltaX: 20, deltaY: 20), .target)
        // Drift far past the window's right edge.
        _ = motion(MouseMotionEvent(x: 1500, y: 1500, deltaX: 1470, deltaY: 1470), .target)

        #expect(controller.dragSession.isOutsideAllHosts == true)
        #expect(controller.dragSession.dropHit == nil)
    } }
}
