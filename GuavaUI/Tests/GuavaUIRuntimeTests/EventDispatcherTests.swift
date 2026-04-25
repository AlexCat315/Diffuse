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
        var hover: [String] = []
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
        interactions.setHover(node) { phase in
            switch phase {
            case .enter: box.recorder.hover.append("\(name):enter")
            case .leave: box.recorder.hover.append("\(name):leave")
            }
        }
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

    @Test("mouseMotion emits hover enter/leave only for changed path segments")
    func hoverPathDiff() {
        let (_, _, _, _, _, dispatcher, box) = setup()

        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: 20, y: 20, deltaX: 1, deltaY: 1)))
        #expect(box.recorder.hover == ["root:enter", "mid:enter", "leaf:enter"])

        box.recorder.hover = []
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: 90, y: 90, deltaX: 1, deltaY: 1)))
        #expect(box.recorder.hover == ["leaf:leave"])

        box.recorder.hover = []
        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: 240, y: 240, deltaX: 1, deltaY: 1)))
        #expect(box.recorder.hover == ["mid:leave", "root:leave"])
    }

    @Test("mouseWheel delivers to the deepest target before ancestors")
    func wheelPrefersDeepestTarget() {
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
                           interactions: interactions, box: box, handle: true)
        let leaf = makeNode(name: "leaf",
                            frame: CGRect(x: 5, y: 5, width: 30, height: 30),
                            interactions: interactions, box: box, handle: true)
        root.addChild(mid)
        mid.addChild(leaf)
        tree.root = root

        let dispatcher = EventDispatcher(
            tree: tree,
            interactions: interactions,
            capture: capture,
            focusChain: focus
        )

        dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: 20, y: 20, deltaX: 0, deltaY: 0)))
        box.recorder = Recorder()
        dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: -1)))

        #expect(box.recorder.capture.isEmpty)
        #expect(box.recorder.target == ["leaf"])
        #expect(box.recorder.bubble.isEmpty)
    }

    @Test("mouseWheel can hit-test from event cursor coordinates without prior motion")
    func wheelUsesEventCursorCoordinates() {
        let tree = NodeTree()
        let interactions = InteractionRegistry()
        let box = Box()

        let root = makeNode(name: "root",
                            frame: CGRect(x: 0, y: 0, width: 200, height: 200),
                            interactions: interactions, box: box)
        let leaf = makeNode(name: "leaf",
                            frame: CGRect(x: 40, y: 40, width: 80, height: 80),
                            interactions: interactions, box: box, handle: true)
        root.addChild(leaf)
        tree.root = root

        let dispatcher = EventDispatcher(
            tree: tree,
            interactions: interactions,
            capture: PointerCapture(),
            focusChain: FocusChain()
        )

        dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: 0,
                                                        y: -1,
                                                        mouseX: 60,
                                                        mouseY: 60)))

        #expect(box.recorder.target == ["leaf"])
        #expect(box.recorder.bubble.isEmpty)
    }

    @Test("High-priority chrome route preempts target controls")
    func chromeRoutePreemptsTargetControl() {
        let tree = NodeTree()
        let interactions = InteractionRegistry()

        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let leaf = Node()
        leaf.frame = CGRect(x: 20, y: 20, width: 80, height: 80)
        root.addChild(leaf)
        tree.root = root

        var calls: [String] = []
        interactions.setPointer(root, route: .scrollChrome) { _, _, phase in
            calls.append("chrome:\(phase)")
            return .handled
        }
        interactions.setPointer(leaf) { _, _, phase in
            calls.append("leaf:\(phase)")
            return .handled
        }

        let dispatcher = EventDispatcher(
            tree: tree,
            interactions: interactions,
            capture: PointerCapture(),
            focusChain: FocusChain()
        )
        var traces: [InputDispatchTrace] = []
        dispatcher.traceSink = { traces.append($0) }

        dispatcher.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left,
                                                              x: 40,
                                                              y: 40,
                                                              clicks: 1)))

        #expect(calls == ["chrome:capture"])
        #expect(traces.first?.route?.role == .scrollChrome)
        #expect(traces.first?.result == .handled)
    }

    @Test("keyUp uses key-up handlers and does not replay key-down handlers")
    func keyUpHasDistinctDelivery() {
        let tree = NodeTree()
        let interactions = InteractionRegistry()
        let focus = FocusChain()

        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let leaf = Node()
        leaf.frame = CGRect(x: 10, y: 10, width: 40, height: 40)
        leaf.isFocusable = true
        root.addChild(leaf)
        tree.root = root
        focus.focus(leaf)

        var downs = 0
        var ups = 0
        interactions.setKey(leaf) { _, _ in
            downs += 1
            return .handled
        }
        interactions.setKeyUp(leaf) { _, _ in
            ups += 1
            return .handled
        }

        let dispatcher = EventDispatcher(
            tree: tree,
            interactions: interactions,
            capture: PointerCapture(),
            focusChain: focus
        )
        let key = KeyEvent(scancode: 44, keycode: 0, modifiers: [], isRepeat: false)

        dispatcher.dispatch(.keyUp(key))
        #expect(downs == 0)
        #expect(ups == 1)

        dispatcher.dispatch(.keyDown(key))
        #expect(downs == 1)
        #expect(ups == 1)
    }

    @Test("Global shortcut route receives key when focus chain ignores it")
    func globalShortcutFallbackReceivesKey() {
        let tree = NodeTree()
        let interactions = InteractionRegistry()
        let focus = FocusChain()

        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let focused = Node()
        focused.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        focused.isFocusable = true
        let global = Node()
        global.frame = CGRect(x: 50, y: 0, width: 40, height: 40)
        root.addChild(focused)
        root.addChild(global)
        tree.root = root
        focus.focus(focused)

        var calls: [String] = []
        interactions.setKey(focused) { _, _ in
            calls.append("focused")
            return .ignored
        }
        interactions.setKey(global, route: .shortcut) { _, phase in
            calls.append("shortcut:\(phase)")
            return .handled
        }

        let dispatcher = EventDispatcher(
            tree: tree,
            interactions: interactions,
            capture: PointerCapture(),
            focusChain: focus
        )
        dispatcher.dispatch(.keyDown(KeyEvent(scancode: 42,
                                              keycode: 0,
                                              modifiers: [],
                                              isRepeat: false)))

        #expect(calls == ["focused", "shortcut:capture"])
    }

    @Test("Focused key handler wins before global shortcut fallback")
    func focusedKeyHandlerWinsBeforeGlobalShortcut() {
        let tree = NodeTree()
        let interactions = InteractionRegistry()
        let focus = FocusChain()

        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let focused = Node()
        focused.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        focused.isFocusable = true
        let global = Node()
        global.frame = CGRect(x: 50, y: 0, width: 40, height: 40)
        root.addChild(focused)
        root.addChild(global)
        tree.root = root
        focus.focus(focused)

        var calls: [String] = []
        interactions.setKey(focused) { _, _ in
            calls.append("focused")
            return .handled
        }
        interactions.setKey(global, route: .shortcut) { _, _ in
            calls.append("shortcut")
            return .handled
        }

        let dispatcher = EventDispatcher(
            tree: tree,
            interactions: interactions,
            capture: PointerCapture(),
            focusChain: focus
        )
        dispatcher.dispatch(.keyDown(KeyEvent(scancode: 42,
                                              keycode: 0,
                                              modifiers: [],
                                              isRepeat: false)))

        #expect(calls == ["focused"])
    }
}
