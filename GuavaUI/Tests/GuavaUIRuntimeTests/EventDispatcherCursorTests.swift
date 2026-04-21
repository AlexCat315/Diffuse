import Testing
import CoreGraphics
import PlatformShell
@testable import GuavaUIRuntime
import EngineKernel

@Suite("EventDispatcher cursor sink")
struct EventDispatcherCursorTests {

    @Test("cursorSink fires when hover crosses into a node with .cursor set")
    func cursorEnter() {
        let (tree, root, leaf, dispatcher) = makeTwoNodeTree()
        leaf.cursor = .pointer

        var received: [SystemCursor] = []
        dispatcher.cursorSink = { received.append($0) }

        // Move into leaf
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: 20, y: 20, deltaX: 0, deltaY: 0)))
        #expect(received == [.pointer])

        _ = (tree, root)
    }

    @Test("Cursor reverts to .arrow when leaving a cursor-bearing node")
    func cursorLeave() {
        let (_, _, leaf, dispatcher) = makeTwoNodeTree()
        leaf.cursor = .pointer

        var received: [SystemCursor] = []
        dispatcher.cursorSink = { received.append($0) }

        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: 20, y: 20, deltaX: 0, deltaY: 0)))
        // Move outside leaf but still inside root
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: 80, y: 80, deltaX: 0, deltaY: 0)))
        #expect(received == [.pointer, .arrow])
    }

    @Test("No sink emission when same cursor stays")
    func cursorStable() {
        let (_, _, leaf, dispatcher) = makeTwoNodeTree()
        leaf.cursor = .pointer

        var received: [SystemCursor] = []
        dispatcher.cursorSink = { received.append($0) }

        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: 20, y: 20, deltaX: 0, deltaY: 0)))
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: 25, y: 25, deltaX: 0, deltaY: 0)))
        #expect(received == [.pointer])
    }

    private func makeTwoNodeTree() -> (NodeTree, Node, Node, EventDispatcher) {
        let tree = NodeTree()
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let leaf = Node()
        leaf.frame = CGRect(x: 10, y: 10, width: 40, height: 40)
        root.addChild(leaf)
        tree.root = root
        let dispatcher = EventDispatcher(
            tree: tree,
            interactions: InteractionRegistry(),
            capture: PointerCapture(),
            focusChain: FocusChain()
        )
        return (tree, root, leaf, dispatcher)
    }
}
