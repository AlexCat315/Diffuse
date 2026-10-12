import Foundation
import Testing
import GuavaUIRuntime

@Suite("Phased scroll routing")
struct WheelInputTests {
    private struct Fixture {
        let tree = NodeTree()
        let registry = InteractionRegistry()
        let focus = FocusChain()
        let left = Node()
        let right = Node()
        let dispatcher: EventDispatcher

        init() {
            dispatcher = EventDispatcher(tree: tree, interactions: registry, capture: PointerCapture(), focusChain: focus)
            let root = Node(); root.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
            left.frame = CGRect(x: 0, y: 0, width: 180, height: 200)
            right.frame = CGRect(x: 200, y: 0, width: 180, height: 200)
            root.addChild(left); root.addChild(right); tree.root = root
        }
        func wheel(_ x: Float, phase: ScrollPhase = .none, momentum: ScrollPhase = .none) {
            dispatcher.dispatch(.mouseWheel(.init(x: 0, y: -5, mouseX: x, mouseY: 50,
                input: .init(unit: .points, device: .continuous, phase: phase, momentumPhase: momentum))))
        }
    }

    @Test("Gesture and OS momentum stay with their consumer; click catches momentum and a new gesture restarts")
    func latchAndInterrupt() {
        let f = Fixture(); var left = 0; var right = 0
        f.registry.setWheel(f.left) { _, _ in left += 1; return .handled }
        f.registry.setWheel(f.right) { _, _ in right += 1; return .handled }
        f.wheel(50, phase: .began)
        f.wheel(250, phase: .changed)
        f.wheel(250, phase: .ended)
        f.wheel(250, momentum: .began)
        #expect(left == 4 && right == 0)
        f.dispatcher.dispatch(.mouseButtonDown(.init(button: .left, x: 250, y: 50, clicks: 1)))
        f.wheel(250, momentum: .changed)
        f.wheel(250, momentum: .ended)
        #expect(left == 4 && right == 0)
        f.wheel(250, phase: .began)
        f.wheel(250, phase: .changed)
        #expect(right == 2)
    }

    @Test("Cancellation and phaseless line wheels release the previous viewport")
    func cancellation() {
        let f = Fixture(); var left = 0; var right = 0
        f.registry.setWheel(f.left) { _, _ in left += 1; return .handled }
        f.registry.setWheel(f.right) { _, _ in right += 1; return .handled }
        f.wheel(50, phase: .began); f.wheel(250, phase: .cancelled)
        f.wheel(250, momentum: .began)
        #expect(left == 2 && right == 0)
        f.wheel(250)
        #expect(left == 2 && right == 1)
    }

    @Test("A global scroll fallback latches its consumer when an overlay intercepted hit testing")
    func globalFallbackLatchesConsumer() {
        let f = Fixture(); var left = 0; var right = 0
        f.registry.setWheel(f.left, route: .scroll) { _, _ in left += 1; return .handled }
        f.registry.setWheel(f.right, route: .control) { _, _ in right += 1; return .handled }
        let overlay = Node(); overlay.frame = f.tree.root!.frame
        overlay.isHitTestable = true
        f.tree.root!.addChild(overlay)
        f.wheel(50, phase: .began)
        #expect(left == 1 && right == 0)
        f.tree.root!.removeChild(overlay)
        f.wheel(250, momentum: .changed)
        #expect(left == 2 && right == 0)
    }

    @Test("A removed consumer cannot transfer its remaining momentum to a neighboring viewport")
    func removal() {
        let f = Fixture(); var right = 0
        f.registry.setWheel(f.left) { _, _ in .handled }
        f.registry.setWheel(f.right) { _, _ in right += 1; return .handled }
        f.wheel(50, phase: .began)
        f.tree.root!.removeChild(f.left)
        f.wheel(250, momentum: .changed)
        #expect(right == 0)
        f.wheel(250, phase: .began)
        #expect(right == 1)
    }

    @Test("A new modal scope prevents a latched background viewport from scrolling")
    func modalTakesOver() {
        let f = Fixture(); var left = 0
        f.registry.setWheel(f.left) { _, _ in left += 1; return .handled }
        f.wheel(50, phase: .began)
        f.focus.beginModal(f.right)
        f.wheel(50, momentum: .changed)
        #expect(left == 1)
    }

    @Test("Resting fingers catch old momentum at mayBegin, before a new pan starts")
    func mayBeginCatchesMomentum() {
        let f = Fixture(); var left = 0
        f.registry.setWheel(f.left) { _, _ in left += 1; return .handled }
        f.wheel(50, momentum: .began)
        f.wheel(50, phase: .mayBegin)
        f.wheel(50, momentum: .changed)
        #expect(left == 2)
        f.wheel(50, phase: .began)
        #expect(left == 3)
    }
}
