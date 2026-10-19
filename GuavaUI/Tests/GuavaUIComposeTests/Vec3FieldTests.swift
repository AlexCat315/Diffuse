import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Editor Vec3Field", .serialized)
struct Vec3FieldTests: GuavaUIComposeSerializedSuite {
    final class Store {
        var x: Float = 1
        var y: Float = 2
        var z: Float = 3
    }

    @Test("Axes share one row when each keeps its minimum, and otherwise stack at full width, never two and one", arguments: [180, 400])
    func axisRows(width: Float) { GlobalTestLock.locked {
        let store = Store()
        let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = old }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root:
            Vec3Field(
                x: Binding(get: { store.x }, set: { store.x = $0 }),
                y: Binding(get: { store.y }, set: { store.y = $0 }),
                z: Binding(get: { store.z }, set: { store.z = $0 })
            )
            .frame(width: width)
        )
        graph.computeLayout(width: width, height: 200)
        let fields = nodes(graph.tree.root!).filter { $0.accessibility?.role == .textField }
        #expect(fields.count == 3)
        // The text field sits 1pt inside its clipped, rounded axis container.
        #expect(fields.allSatisfy { $0.absoluteFrame.minX >= -0.5 && $0.absoluteFrame.maxX <= CGFloat(width) + 1.5 && $0.frame.width >= 40 })
        #expect(Set(fields.map { $0.frame.width.rounded() }).count == 1, "axes are equal width")
        #expect(Set(fields.map { $0.absoluteFrame.minY.rounded() }).count == (width < 280 ? 3 : 1))
        graph.install(root: EmptyView())
    } }

    private func nodes(_ node: Node) -> [Node] { [node] + node.children.flatMap(nodes) }

    @Test("Scrubbing scales the drag by the step, Shift and Option, and clamps")
    func scrubMath() {
        let scrub = NumericScrub(perPoint: 0.25, clamp: { min(max($0, -10), 10) }, reset: 0)
        #expect(scrub.value(from: 1, dragged: 8, modifiers: []) == 3)
        #expect(scrub.value(from: 1, dragged: 8, modifiers: [.shift]) == 10)
        #expect(abs(scrub.value(from: 1, dragged: 8, modifiers: [.alt]) - 1.2) < 0.0001)
        #expect(scrub.value(from: 1, dragged: -400, modifiers: []) == -10)
    }

    @Test("Vectors copy without locale and paste from common spellings")
    func vectorText() {
        #expect(Vec3Field.format(SIMD3(1, -2.5, 0)) == "1, -2.5, 0")
        for text in ["1, -2.5, 0", "(1 -2.5 0)", "Vector3(1, -2.5, 0)", " [1;-2.5;0] ", "1\t-2.5\t0"] {
            #expect(Vec3Field.parse(text) == SIMD3(1, -2.5, 0), "\(text)")
        }
        for text in ["1, 2", "1, 2, 3, 4", "a, b, c", "1, nan, 2", ""] { #expect(Vec3Field.parse(text) == nil, "\(text)") }
    }

    @Test("Dragging an axis chip scrubs that axis; double-click resets it; the menu pastes and resets the vector")
    func scrubResetAndPaste() throws { try GlobalTestLock.locked {
        let store = Store()
        let old = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        let oldRead = ClipboardHolder.read, oldWrite = ClipboardHolder.write
        var clipboard = "Vector3(4, 5, 6)"
        ClipboardHolder.read = { clipboard }; ClipboardHolder.write = { clipboard = $0 }
        defer { TextEnvironmentHolder.current = old; ClipboardHolder.read = oldRead; ClipboardHolder.write = oldWrite }
        let context = PlatformInputContext()
        try context.withCurrent {
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: LayerRoot { Vec3Field(x: Binding(get: { store.x }, set: { store.x = $0 }),
                                          y: Binding(get: { store.y }, set: { store.y = $0 }),
                                          z: Binding(get: { store.z }, set: { store.z = $0 }),
                                          step: 0.1, resetValue: SIMD3(0, 0, 0)).frame(width: 420) })
            for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 420, height: 100) }
            defer { graph.install(root: EmptyView()) }
            let chips = nodes(graph.tree.root!).filter { $0.cursor == .resizeHorizontal }
                .sorted { $0.absoluteFrame.minX < $1.absoluteFrame.minX }
#expect(chips.count == 3 && chips.allSatisfy { $0.cursor == .resizeHorizontal })
            let input = EventDispatcher(tree: graph.tree, interactions: context.interactions, capture: context.pointerCapture, focusChain: context.focusChain)
            let x = Float(chips[0].absoluteFrame.midX), y = Float(chips[0].absoluteFrame.midY)
            input.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left, x: x, y: y, clicks: 1)))
            input.dispatch(.mouseMotion(MouseMotionEvent(x: x + 40, y: y, deltaX: 40, deltaY: 0)))
            input.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: x + 40, y: y, clicks: 1)))
            #expect(abs(store.x - 2) < 0.0001 && store.y == 2)   // 40pt × 0.1 / 4
            input.dispatch(.mouseButtonDown(MouseButtonEvent(button: .left, x: x, y: y, clicks: 2)))
            input.dispatch(.mouseButtonUp(MouseButtonEvent(button: .left, x: x, y: y, clicks: 2)))
            #expect(store.x == 0 && store.y == 2)
            let row = try #require(nodes(graph.tree.root!).first { $0.children.count == 3 })
            let menu = row.absoluteFrame
            input.dispatch(.mouseButtonDown(MouseButtonEvent(button: .right, x: Float(menu.maxX - 2), y: Float(menu.midY), clicks: 1)))
            input.dispatch(.mouseButtonUp(MouseButtonEvent(button: .right, x: Float(menu.maxX - 2), y: Float(menu.midY), clicks: 1)))
            for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 420, height: 400) }
            let paste = try #require(nodes(graph.tree.root!).first { $0.accessibility?.label == "Paste Vector" })
            paste.accessibilityActions.activate?()
            #expect((store.x, store.y, store.z) == (4, 5, 6))
        }
    } }

    private func firstNode(in root: Node, where predicate: (Node) -> Bool) -> Node? {
        if predicate(root) { return root }
        for child in root.children {
            if let match = firstNode(in: child, where: predicate) {
                return match
            }
        }
        return nil
    }
}
