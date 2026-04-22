import Testing
import CoreGraphics
import GuavaUIRuntime
import EngineKernel
@testable import GuavaUICompose

/// Phase G — gesture intent ladder. Verifies the four-rung escalation
/// model on top of the existing drag plumbing:
///   pendingClick → reorderInStrip → detachOrSplit
/// plus the contract that escalation is monotonic (no fall-back) and that
/// the leaf-handle drag bypasses the reorder rung entirely.
@Suite("Phase G Dock gesture intent", .serialized)
struct DockGestureIntentTests: GuavaUIComposeSerializedSuite {

    private func makeContent() -> DockContentResolver {
        return { key in AnyView(Text("k:\(key)")) }
    }

    private func findTabItems(_ root: Node) -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) {
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

    /// Locate the leaf-strip drag handle. It's the only hit-testable
    /// descendant with `cursor == .move`.
    private func findLeafHandles(_ root: Node) -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) {
            if n.isHitTestable, n.cursor == .move { out.append(n) }
            for c in n.children { walk(c) }
        }
        walk(root)
        return out
    }

    private func wireEnv() {
        InteractionRegistryHolder.current = InteractionRegistry()
        PointerCaptureHolder.current = PointerCapture()
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
    }

    // MARK: motion below the reorder threshold ⇒ no drag at all

    @Test("Motion below 4 px keeps intent at .pendingClick (drag not started)")
    func belowReorderThreshold() { GlobalTestLock.locked {
        wireEnv()
        defer { PointerCaptureHolder.current = nil }
        let registry = InteractionRegistryHolder.current!

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
        _ = motion(MouseMotionEvent(x: 12, y: 11, deltaX: 2, deltaY: 1), .target)

        #expect(controller.dragSession.isActive == false)
        #expect(controller.dragSession.intent == .pendingClick)
    } }

    @Test("Pure vertical wobble below the lift threshold stays a click")
    func verticalWobbleStaysClick() { GlobalTestLock.locked {
        wireEnv()
        defer { PointerCaptureHolder.current = nil }
        let registry = InteractionRegistryHolder.current!

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
        _ = motion(MouseMotionEvent(x: 10, y: 15, deltaX: 0, deltaY: 5), .target)

        #expect(controller.dragSession.isActive == false)
        #expect(controller.dragSession.intent == .pendingClick)
    } }

    // MARK: motion in the [4, 12) band ⇒ .reorderInStrip

    @Test("Motion in [4, 12) band starts the drag at .reorderInStrip")
    func reorderBand() { GlobalTestLock.locked {
        wireEnv()
        defer { PointerCaptureHolder.current = nil }
        let registry = InteractionRegistryHolder.current!

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
        // 6 px horizontal, 1 px vertical — past reorder, below lift.
        _ = motion(MouseMotionEvent(x: 16, y: 11, deltaX: 6, deltaY: 1), .target)

        #expect(controller.dragSession.isActive)
        #expect(controller.dragSession.intent == .reorderInStrip)
    } }

    // MARK: motion ≥ 12 px ⇒ straight to .detachOrSplit

    @Test("Motion ≥ 12 px starts the drag at .detachOrSplit")
    func liftBand() { GlobalTestLock.locked {
        wireEnv()
        defer { PointerCaptureHolder.current = nil }
        let registry = InteractionRegistryHolder.current!

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
        #expect(controller.dragSession.intent == .detachOrSplit)
    } }

    // MARK: vertical jab inside the reorder band still escalates to lift

    @Test("Short vertical jab (≥8 px dy) immediately escalates to .detachOrSplit")
    func verticalJabEscalates() { GlobalTestLock.locked {
        wireEnv()
        defer { PointerCaptureHolder.current = nil }
        let registry = InteractionRegistryHolder.current!

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
        // 5 px horizontal (would normally be reorder), 9 px vertical — past
        // the vertical-jab threshold so the drag should start at lift tier.
        _ = motion(MouseMotionEvent(x: 15, y: 19, deltaX: 5, deltaY: 9), .target)

        #expect(controller.dragSession.intent == .detachOrSplit)
    } }

    // MARK: monotonic — once at reorder, sliding back below 4 px stays at reorder

    @Test("Reorder→back-near-origin does NOT downgrade the intent")
    func reorderDoesNotDowngrade() { GlobalTestLock.locked {
        wireEnv()
        defer { PointerCaptureHolder.current = nil }
        let registry = InteractionRegistryHolder.current!

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
        _ = motion(MouseMotionEvent(x: 16, y: 11, deltaX: 6, deltaY: 1), .target)
        #expect(controller.dragSession.intent == .reorderInStrip)
        // Drag back to within 2 px of origin.
        _ = motion(MouseMotionEvent(x: 11, y: 10, deltaX: -5, deltaY: -1), .target)
        #expect(controller.dragSession.intent == .reorderInStrip)
    } }

    // MARK: monotonic — reorder followed by lift escalates

    @Test("Reorder followed by lift-tier motion escalates")
    func reorderEscalatesToLift() { GlobalTestLock.locked {
        wireEnv()
        defer { PointerCaptureHolder.current = nil }
        let registry = InteractionRegistryHolder.current!

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
        _ = motion(MouseMotionEvent(x: 16, y: 11, deltaX: 6, deltaY: 1), .target)
        #expect(controller.dragSession.intent == .reorderInStrip)
        _ = motion(MouseMotionEvent(x: 30, y: 30, deltaX: 14, deltaY: 19), .target)
        #expect(controller.dragSession.intent == .detachOrSplit)
    } }

    // MARK: leaf-handle drag bypasses the reorder rung entirely

    @Test("Leaf-handle drag waits for the lift threshold and starts at .detachOrSplit")
    func leafHandleStartsAtLift() { GlobalTestLock.locked {
        wireEnv()
        defer { PointerCaptureHolder.current = nil }
        let registry = InteractionRegistryHolder.current!

        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([a])
        let leafB = DockLayoutNode.tabs([b])
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)
        let handles = findLeafHandles(tree.root!)
        #expect(handles.count >= 1, "expected at least one leaf-handle node")
        let handle = handles[0]
        let pointer = registry.handlers(for: handle).pointer!
        let motion  = registry.handlers(for: handle).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1), .down, .target)
        // 6 px — below the 12 px lift threshold for the leaf handle.
        _ = motion(MouseMotionEvent(x: 16, y: 11, deltaX: 6, deltaY: 1), .target)
        #expect(controller.dragSession.isActive == false,
                "leaf-handle drag must wait for the lift threshold")
        // 14 px — past the lift threshold.
        _ = motion(MouseMotionEvent(x: 24, y: 11, deltaX: 8, deltaY: 0), .target)
        #expect(controller.dragSession.isActive)
        #expect(controller.dragSession.intent == .detachOrSplit)
    } }
}
