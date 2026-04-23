import Testing
import GuavaUIRuntime
import EngineKernel
import PlatformShell
@testable import GuavaUICompose

/// Phase D8.2 — Esc key cancels an in-flight DockDragSession via the
/// EventDispatcher pointer-capture intercept. Drives the registered key
/// handler on a dragging tab node; verifies session.isActive flips back
/// to false without firing any controller op.
@Suite("Phase D8 / Dock Esc cancel", .serialized)
struct DockEscCancelTests: GuavaUIComposeSerializedSuite {

    private func makeContent() -> DockContentResolver {
        return { key in AnyView(Text("k:\(key)")) }
    }

    private func findHitItems(_ root: Node, cursor: SystemCursor) -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) {
            if n.isHitTestable, n.cursor == cursor { out.append(n) }
            for c in n.children { walk(c) }
        }
        walk(root)
        return out
    }

    @Test("Esc on a dragging tab cancels the session and fires no controller op")
    func escCancelsTabDrag() { GlobalTestLock.locked {
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

        let tabNode = findHitItems(tree.root!, cursor: .pointer)[0]
        let pointer = registry.handlers(for: tabNode).pointer!
        let motion  = registry.handlers(for: tabNode).motion!
        let key     = registry.handlers(for: tabNode).key!

        _ = pointer(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 40, y: 40, deltaX: 30, deltaY: 30), .target)
        #expect(controller.dragSession.isActive)

        let versionBefore = controller.version
        let result = key(KeyEvent(scancode: DOCK_KEY_SCANCODE_ESC,
                                  keycode: 0,
                                  modifiers: [],
                                  isRepeat: false), .target)
        #expect(result == .handled)
        #expect(controller.dragSession.isActive == false)
        #expect(controller.version == versionBefore)
        #expect(PointerCaptureHolder.current?.target == nil)
    } }

    @Test("Esc returns ignored when no drag is active (does not swallow)")
    func escIgnoredWhenIdle() { GlobalTestLock.locked {
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

        let tabNode = findHitItems(tree.root!, cursor: .pointer)[0]
        let key = registry.handlers(for: tabNode).key!
        let result = key(KeyEvent(scancode: DOCK_KEY_SCANCODE_ESC,
                                  keycode: 0,
                                  modifiers: [],
                                  isRepeat: false), .target)
        #expect(result == .ignored)
    } }

    @Test("Non-Esc scancodes pass through (return ignored)")
    func nonEscPassesThrough() { GlobalTestLock.locked {
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

        let tabNode = findHitItems(tree.root!, cursor: .pointer)[0]
        let pointer = registry.handlers(for: tabNode).pointer!
        let motion  = registry.handlers(for: tabNode).motion!
        let key     = registry.handlers(for: tabNode).key!

        _ = pointer(MouseButtonEvent(button: .left, x: 10, y: 10, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 40, y: 40, deltaX: 30, deltaY: 30), .target)
        #expect(controller.dragSession.isActive)

        // A random scancode (4 = SDL_SCANCODE_A) — the handler must not
        // consume it.
        let result = key(KeyEvent(scancode: 4, keycode: 0, modifiers: [], isRepeat: false), .target)
        #expect(result == .ignored)
        #expect(controller.dragSession.isActive)
    } }
}
