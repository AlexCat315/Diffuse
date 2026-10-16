import Foundation
import GuavaUIRuntime
import Testing
@testable import GuavaUICompose

@Suite("Retained visibility paint", .serialized)
struct RetainedVisibilityTests: GuavaUIComposeSerializedSuite {
    private struct Painter: _PrimitiveView {
        func _makeNode() -> Node { Node() }
        func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
        func _updateNode(_ node: Node) {
            // Text and icons may paint their intrinsic size even with a zero
            // Yoga frame. This overdraw reproduces hidden navigation headings.
            node.draw = { list, origin in
                list.addRect(UIRect(x: Float(origin.x), y: Float(origin.y), width: 40, height: 20), color: Color(r: 1, g: 0, b: 0, a: 1))
            }
        }
    }
    private final class Harness: View {
        @State var visible = false
        let transition: Transition
        init(_ transition: Transition) { self.transition = transition }
        var body: some View {
            Box(direction: .column, alignItems: .stretch) {
                AnimatedVisibility(isVisible: visible, transition: transition, retainsContent: true) {
                    Painter().frame(width: 40, height: 20).debugName("retained-painter")
                }
            }.reducedMotion()
        }
    }

    private func painter(in root: Node?) -> Node? {
        var pending = root.map { [$0] } ?? []
        while let node = pending.popLast() {
            if node.attachments[LayoutDebugAttachmentKey.debugName] as? String == "retained-painter" { return node }
            pending.append(contentsOf: node.children)
        }
        return nil
    }

    @Test("Identity and movement exits hide retained custom painters in direct and cached rendering")
    func hiddenPaint() throws {
        try GlobalTestLock.locked {
            for transition: Transition in [.identity, .move(edge: .leading, distance: 10)] {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let harness = Harness(transition), renderer = LayerAwareNodeRenderer()
                graph.install(root: harness)
                defer { graph.install(root: EmptyView()) }
                var painterID: ElementID?
                for visible in [false, true, false, true] {
                    harness.visible = visible
                    for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 160, height: 100) }
                    let painter = try #require(painter(in: graph.tree.root))
                    if let painterID { #expect(painter.id == painterID) }
                    painterID = painter.id
                    let direct = DrawList(); NodeRenderer().render(root: try #require(graph.tree.root), into: direct)
                    #expect(direct.vertices.contains { $0.color >> 24 > 0 } == visible)
                    // Second render exercises cached layers, including reuse after re-showing.
                    for _ in 0..<2 {
                        let cached = DrawList(); renderer.render(tree: graph.renderTree, into: cached)
                        #expect(cached.vertices.contains { $0.color >> 24 > 0 } == visible)
                    }
                }
            }
        }
    }
}
