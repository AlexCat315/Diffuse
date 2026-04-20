import Testing
import CoreGraphics
@testable import GuavaUIRuntime
import EngineKernel

@Suite("EventDispatcher")
struct EventDispatcherTests {

    private struct Recorder {
        var capture: [String] = []
        var target: [String] = []
        var bubble: [String] = []
    }

    private final class Box { var recorder = Recorder() }

    private func makeNode(name: String,
                          frame: CGRect,
                          interactions: InteractionRegistry,
                          box: Box,
                          handle: Bool = false) -> Node {
        let node = Node()
        node.frame = frame
        let record: (EventPhase) -> EventResult = { phase in
            switch phase {
            case .capture: box.recorder.capture.append(name)
            case .target:  box.recorder.target.append(name)
            case .bubble:  box.recorder.bubble.append(name)
            }
            return handle ? .handled : .ignored
        }
        interactions.setPointer(node) { _, _, phase in record(phase) }
        interactions.setMotion(node)  { _, phase in record(phase) }
        interactions.setWheel(node)   { _, phase in record(phase) }
        interactions.setKey(node)     { _, phase in record(phase) }
        return node
    }

    private func setup() -> (NodeTree, Node, Node, Node, InteractionRegistry, EventDispatcher, Box) {
        let tree = NodeTree()
        let interactions = InteractionRegistry()
        let capture = PointerCapture()
        let focus = FocusChain()
        let box = Box()

        let root = makeNode(name: "root",
                            frame: CGRect(x: 0, y: 0, width: 200, height: 200),
                            interactions: interactions, box: box)
        let mid = makeNode(name: "mid",
                           frame: CGRect(x: 10, y: 10, width: 100, height: 100),
                           interactions: interactions, box: box)
        let leaf = makeNode(name: "leaf",
                            frame: CGRect(x: 5, y: 5, width: 30, height: 30),
                            interactions: interactions, box: box)
        root.addChild(mid)
        mid.addChild(leaf)
        tree.root = root

        let dispatcher = EventDispatcher(
            tree: tree, interactions: interactions,
            capture: capture, focusChain: focus
        )
        return (tree, root, mid, leaf, interactions, dispatcher, box)
    }

    @Test("Pointer down: capture root→mid, target leaf, bubble mid→root")
    func captureTargetBubble() {
        let (_, _, _, _, _, dispatcher, box) = setup()

        // Point lands inside leaf (root 0,0 + mid 10,10 + leaf 5,5 = 15,15;
        // leaf is 30x30 so a point at 20,20 is well inside).
        let event = MouseButtonEvent(button: .left, x: 20, y: 20, clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(event))

        #expect(box.recorder.capture == ["root", "mid"])
        #expect(box.recorder.target == ["leaf"])
        #expect(box.recorder.bubble == ["mid", "root"])
    }

    @Test("Handled in capture stops propagation")
    func captureHandled() {
        let tree = NodeTree()
        let interactions = InteractionRegistry()
        let capture = PointerCapture()
        let focus = FocusChain()
        let box = Box()

        let root = makeNode(name: "root",
                            frame: CGRect(x: 0, y: 0, width: 200, height: 200),
                            interactions: interactions, box: box, handle: true)
        let leaf = makeNode(name: "leaf",
                            frame: CGRect(x: 10, y: 10, width: 30, height: 30),
                            interactions: interactions, box: box)
        root.addChild(leaf)
        tree.root = root

        let dispatcher = EventDispatcher(
            tree: tree, interactions: interactions,
            capture: capture, focusChain: focus
        )

        let event = MouseButtonEvent(button: .left, x: 20, y: 20, clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(event))

        #expect(box.recorder.capture == ["root"])
        #expect(box.recorder.target.isEmpty)
        #expect(box.recorder.bubble.isEmpty)
    }

    @Test("PointerCapture overrides hit-testing for motion events")
    func pointerCaptureMotion() {
        let (_, _, _, leaf, _, dispatcher, box) = setup()
        dispatcher.capture.acquire(leaf)

        // Point far outside leaf — would normally miss or land elsewhere.
        let event = MouseMotionEvent(x: 500, y: 500, deltaX: 1, deltaY: 1)
        dispatcher.dispatch(.mouseMotion(event))

        // Capture target should still receive it (target phase = "leaf").
        #expect(box.recorder.target == ["leaf"])
    }

    @Test("Auto-focus on click for focusable nodes")
    func autoFocus() {
        let (_, _, _, leaf, _, dispatcher, _) = setup()
        leaf.isFocusable = true

        let event = MouseButtonEvent(button: .left, x: 20, y: 20, clicks: 1)
        dispatcher.dispatch(.mouseButtonDown(event))

        #expect(dispatcher.focusChain.focused === leaf)
    }
}
