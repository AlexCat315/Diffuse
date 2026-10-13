import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Nested scroll routing")
struct NestedScrollRoutingTests {
    private struct Fixture {
        let tree: NodeTree
        let registry: InteractionRegistry
        let graph: ViewGraph
        let dispatcher: EventDispatcher
        let outer: Node
        let inner: Node

        init(contentHeight: Float = 500,
             axis: ScrollAxis = .vertical,
             policy: ScrollConsumePolicy? = nil) {
            let registry = InteractionRegistry()
            InteractionRegistryHolder.current = registry
            let tree = NodeTree()
            let graph = ViewGraph(tree: tree, recomposer: Recomposer())
            let content = AnyView(Box {}.frame(width: axis == .horizontal ? 500 : 180,
                                              height: contentHeight))
            let innerView: AnyView
            if let policy {
                innerView = AnyView(ScrollView(axis, consumePolicy: policy) { content })
            } else {
                innerView = AnyView(ScrollView(axis) { content })
            }
            graph.install(root: ScrollView {
                Box(direction: .column, alignItems: .stretch) {
                    innerView.frame(height: 150).debugName("nested-inner")
                    Box {}.frame(height: 600)
                }.flex(0, shrink: 0)
            }.frame(width: 200, height: 300).debugName("nested-outer"))
            graph.computeLayout(width: 200, height: 300)
            func find(_ name: String, in node: Node) -> Node? {
                if node.attachments[LayoutDebugAttachmentKey.debugName] as? String == name { return node }
                for child in node.children {
                    if let result = find(name, in: child) { return result }
                }
                return nil
            }
            self.tree = tree
            self.registry = registry
            self.graph = graph
            outer = find("nested-outer", in: tree.root!)!
            inner = find("nested-inner", in: tree.root!)!
            dispatcher = EventDispatcher(tree: tree, interactions: registry,
                                         capture: PointerCapture(), focusChain: FocusChain())
        }

        func wheel(x: Float = 0, y: Float, pointerY: Float = 40,
                   input: ScrollInput = .init()) {
            dispatcher.dispatch(.mouseMotion(.init(x: 40, y: pointerY, deltaX: 0, deltaY: 0)))
            dispatcher.dispatch(.mouseWheel(.init(x: x, y: y, mouseX: 40, mouseY: pointerY, input: input)))
        }
    }

    @Test("Fresh line wheels stay in an overflowing child at both bounds; moving to the parent scrolls it")
    func lineWheelBoundaries() { GlobalTestLock.locked {
        let fixture = Fixture()
        fixture.wheel(y: 1)
        #expect(fixture.inner.contentOffset == .zero)
        #expect(fixture.outer.contentOffset == .zero)

        fixture.wheel(y: -100)
        #expect(fixture.inner.contentOffset.y == 350)
        for _ in 0..<3 { fixture.wheel(y: -1) }
        #expect(fixture.inner.contentOffset.y == 350)
        #expect(fixture.outer.contentOffset == .zero)

        fixture.wheel(y: -1, pointerY: 220)
        #expect(fixture.outer.contentOffset.y == 30)
        fixture.wheel(y: 100)
        fixture.wheel(y: 1)
        #expect(fixture.inner.contentOffset == .zero)
        #expect(fixture.outer.contentOffset.y == 30)
    } }

    @Test("Gesture continuation, OS momentum, and a fresh gesture at a child boundary do not chain")
    func phasedBoundaries() { GlobalTestLock.locked {
        let fixture = Fixture()
        fixture.wheel(y: -400, input: .init(unit: .points, device: .continuous, phase: .began))
        #expect(fixture.inner.contentOffset.y == 350)
        fixture.wheel(y: -12, pointerY: 220,
                      input: .init(unit: .points, device: .continuous, phase: .changed))
        fixture.wheel(y: 0, input: .init(unit: .points, device: .continuous, phase: .ended))
        fixture.wheel(y: -8, pointerY: 220,
                      input: .init(unit: .points, device: .continuous, momentumPhase: .began))
        fixture.wheel(y: -4, pointerY: 220,
                      input: .init(unit: .points, device: .continuous, momentumPhase: .changed))
        fixture.wheel(y: 0, input: .init(unit: .points, device: .continuous, momentumPhase: .ended))
        fixture.wheel(y: -9, input: .init(unit: .points, device: .continuous, phase: .began))
        #expect(fixture.inner.contentOffset.y == 350)
        #expect(fixture.outer.contentOffset == .zero)

        // A fresh stream over the parent releases the child's ownership.
        fixture.wheel(y: -13, pointerY: 220,
                      input: .init(unit: .points, device: .continuous, phase: .began))
        #expect(fixture.outer.contentOffset.y == 13)
        let held = fixture.outer.contentOffset
        for _ in 0..<120 { AnimatorScheduler.current.tick(deltaTime: 1.0 / 60.0) }
        #expect(fixture.outer.contentOffset == held)
        #expect(fixture.inner.contentOffset.y == 350)
    } }

    @Test("A child with no overflow lets the parent scroll; explicit always can contain it")
    func noOverflow() { GlobalTestLock.locked {
        let fixture = Fixture(contentHeight: 100)
        fixture.wheel(y: -1)
        #expect(fixture.inner.contentOffset == .zero)
        #expect(fixture.outer.contentOffset.y == 30)

        let isolated = Fixture(contentHeight: 100, policy: .always)
        isolated.wheel(y: -1)
        #expect(isolated.inner.contentOffset == .zero)
        #expect(isolated.outer.contentOffset == .zero)
    } }

    @Test("A horizontal child passes vertical input and contains only its overflowing horizontal axis")
    func orthogonalAxes() { GlobalTestLock.locked {
        let fixture = Fixture(contentHeight: 100, axis: .horizontal)
        fixture.wheel(y: -1)
        #expect(fixture.inner.contentOffset == .zero)
        #expect(fixture.outer.contentOffset.y == 30)
        fixture.wheel(x: -100, y: 0)
        let bound = fixture.inner.contentOffset.x
        #expect(bound == 300)
        fixture.wheel(x: -1, y: 0)
        #expect(fixture.inner.contentOffset.x == bound)
        #expect(fixture.outer.contentOffset.y == 30)
    } }

    @Test("Offset-change policy explicitly enables same-axis boundary chaining")
    func explicitChaining() { GlobalTestLock.locked {
        let fixture = Fixture(policy: .whenOffsetChanged)
        fixture.wheel(y: -100)
        #expect(fixture.inner.contentOffset.y == 350)
        #expect(fixture.outer.contentOffset == .zero)
        fixture.wheel(y: -1)
        #expect(fixture.inner.contentOffset.y == 350)
        #expect(fixture.outer.contentOffset.y == 30)
    } }
}
