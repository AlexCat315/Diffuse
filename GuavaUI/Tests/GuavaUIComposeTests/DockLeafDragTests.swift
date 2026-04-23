import Testing
import GuavaUIRuntime
import EngineKernel
import PlatformShell
@testable import GuavaUICompose

@Suite("Phase D8 / Dock leaf drag", .serialized)
struct DockLeafDragTests: GuavaUIComposeSerializedSuite {

    private func makeContent() -> DockContentResolver {
        return { key in AnyView(Text("k:\(key)")) }
    }

    private func findLeafHandles(_ root: Node) -> [Node] {
        var out: [Node] = []
        func walk(_ n: Node) {
            if n.isHitTestable, n.cursor == .move { out.append(n) }
            for c in n.children { walk(c) }
        }
        walk(root)
        return out
    }

    @Test("Drag the leaf handle starts a .mainTreeLeaf session and release fires moveLeaf")
    func leafHandleDragMovesLeaf() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let leafA = DockLayoutNode.tabs([a])
        let leafB = DockLayoutNode.tabs([b])
        let leafAID = leafA.id
        let controller = DockController(root: .hsplit(first: leafA, second: leafB))

        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let handles = findLeafHandles(tree.root!)
        #expect(handles.count == 2)
        let handleA = handles[0]
        let pointer = registry.handlers(for: handleA).pointer!
        let motion  = registry.handlers(for: handleA).motion!

        _ = pointer(MouseButtonEvent(button: .left, x: 4, y: 4, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 30, y: 30, deltaX: 26, deltaY: 26), .target)

        #expect(controller.dragSession.isActive)
        #expect(controller.dragSession.tabID == nil)
        if case .mainTreeLeaf(let id) = controller.dragSession.origin {
            #expect(id == leafAID)
        } else {
            Issue.record("expected .mainTreeLeaf origin"); return
        }

        _ = motion(MouseMotionEvent(x: 450, y: 200, deltaX: 0, deltaY: 0), .target)
        #expect(controller.dragSession.dropHit != nil)

        let versionBefore = controller.version
        let up = pointer(MouseButtonEvent(button: .left, x: 450, y: 200, clicks: 1), .up, .target)
        #expect(up == .handled)
        #expect(controller.version > versionBefore)
        #expect(controller.dragSession.isActive == false)

        var foundA = false
        func walk(_ node: DockLayoutNode) {
            if case .tabs(_, let tabs, _) = node, tabs.contains(where: { $0.id == a.id }) {
                foundA = true
            }
            if case .split(_, _, _, let f, let s) = node {
                walk(f); walk(s)
            }
        }
        walk(controller.root)
        #expect(foundA)
    } }

    @Test("Esc on a dragging leaf handle cancels the session")
    func escCancelsLeafDrag() { GlobalTestLock.locked {
        let registry = InteractionRegistry()
        InteractionRegistryHolder.current = registry
        PointerCaptureHolder.current = PointerCapture()
        defer { PointerCaptureHolder.current = nil }
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()

        let a = DockTab(userKey: "a", title: "A")
        let b = DockTab(userKey: "b", title: "B")
        let controller = DockController(root: .hsplit(
            first: .tabs([a]),
            second: .tabs([b])
        ))
        let tree = NodeTree()
        let graph = ViewGraph(tree: tree, recomposer: Recomposer())
        graph.install(root: DockContainer(controller: controller, content: makeContent()))
        graph.computeLayout(width: 600, height: 400)

        let handles = findLeafHandles(tree.root!)
        let handle = handles[0]
        let pointer = registry.handlers(for: handle).pointer!
        let motion  = registry.handlers(for: handle).motion!
        let key     = registry.handlers(for: handle).key!

        _ = pointer(MouseButtonEvent(button: .left, x: 4, y: 4, clicks: 1), .down, .target)
        _ = motion(MouseMotionEvent(x: 40, y: 40, deltaX: 36, deltaY: 36), .target)
        #expect(controller.dragSession.isActive)

        let versionBefore = controller.version
        let result = key(KeyEvent(scancode: DOCK_KEY_SCANCODE_ESC,
                                  keycode: 0,
                                  modifiers: [],
                                  isRepeat: false), .target)
        #expect(result == .handled)
        #expect(controller.dragSession.isActive == false)
        #expect(controller.version == versionBefore)
    } }
}
