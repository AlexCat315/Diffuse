import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Range slider", .serialized)
struct RangeSliderTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    private func withScene(_ test: (ViewGraph, InteractionRegistry, FocusChain, PointerCapture) -> Void) {
        GlobalTestLock.locked {
            let oldRegistry = InteractionRegistryHolder.current
            let oldFocus = FocusChainHolder.current
            let oldCapture = PointerCaptureHolder.current
            let registry = InteractionRegistry(), focus = FocusChain(), capture = PointerCapture()
            InteractionRegistryHolder.current = registry
            FocusChainHolder.current = focus
            PointerCaptureHolder.current = capture
            defer {
                InteractionRegistryHolder.current = oldRegistry
                FocusChainHolder.current = oldFocus
                PointerCaptureHolder.current = oldCapture
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            test(graph, registry, focus, capture)
            graph.install(root: EmptyView())
            AnimatorScheduler.current.tick(deltaTime: 1)
        }
    }

    private func slider(_ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.accessibility?.role == .slider })
    }

    private func point(_ node: Node, fraction: Float) -> Float {
        Float(node.absoluteOrigin.x) + Float(node.frame.width) * fraction
    }

    @Test("Pointer drag chooses the nearest thumb and clamps to the range")
    func pointerDrag() {
        withScene { graph, registry, focus, capture in
            var values: ClosedRange<Double> = 20...80
            graph.install(root: Row {
                RangeSlider(values: Binding(get: { values }, set: { values = $0 }),
                            in: 0...100, step: 1, minimumSpan: 5)
                    .frame(width: 200)
            })
            graph.computeLayout(width: 400, height: 100)
            guard let node = try? slider(graph) else {
                Issue.record("range slider was not mounted")
                return
            }
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry,
                                             capture: capture, focusChain: focus)
            let down = MouseButtonEvent(button: .left, x: point(node, fraction: 0.2), y: 10, clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(down))
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: point(node, fraction: 0.1), y: 10,
                                                              deltaX: -20, deltaY: 0)))
            dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left,
                                                                 x: point(node, fraction: 0.1),
                                                                 y: 10, clicks: 1)))
            graph.recomposer.commitAll()
            #expect(values.lowerBound == 10)
            #expect(values.upperBound == 80)
            #expect(node.accessibility?.value == "10 – 80")
        }
    }

    @Test("Minimum span prevents the thumbs from crossing")
    func minimumSpan() {
        withScene { graph, registry, focus, capture in
            var values: ClosedRange<Double> = 40...60
            graph.install(root: Row {
                RangeSlider(values: Binding(get: { values }, set: { values = $0 }),
                            in: 0...100, step: 1, minimumSpan: 10)
                    .frame(width: 200)
            })
            graph.computeLayout(width: 400, height: 100)
            guard let node = try? slider(graph) else {
                Issue.record("range slider was not mounted")
                return
            }
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry,
                                             capture: capture, focusChain: focus)
            let down = MouseButtonEvent(button: .left, x: point(node, fraction: 0.4), y: 10, clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(down))
            dispatcher.dispatch(.mouseMotion(MouseMotionEvent(x: point(node, fraction: 0.6), y: 10,
                                                              deltaX: 40, deltaY: 0)))
            dispatcher.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left,
                                                                 x: point(node, fraction: 0.6),
                                                                 y: 10, clicks: 1)))
            #expect(values.lowerBound == 50)
            #expect(values.upperBound == 60)
        }
    }

    @Test("Keyboard moves the active thumb with step and Home/End")
    func keyboard() {
        withScene { graph, registry, focus, capture in
            var values: ClosedRange<Double> = 20...80
            graph.install(root: Row {
                RangeSlider(values: Binding(get: { values }, set: { values = $0 }),
                            in: 0...100, step: 1)
                    .frame(width: 200)
            })
            graph.computeLayout(width: 400, height: 100)
            guard let node = try? slider(graph) else {
                Issue.record("range slider was not mounted")
                return
            }
            focus.focus(node)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: registry,
                                             capture: capture, focusChain: focus)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.arrowRight, keycode: 0,
                                                  modifiers: [], isRepeat: false)))
            #expect(values.lowerBound == 21)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.end, keycode: 0,
                                                  modifiers: [], isRepeat: false)))
            #expect(values.lowerBound == 80)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.home, keycode: 0,
                                                  modifiers: [], isRepeat: false)))
            #expect(values.lowerBound == 0)
        }
    }
}
