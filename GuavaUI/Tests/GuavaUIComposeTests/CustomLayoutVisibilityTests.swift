import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

private struct VisibilityLayout: Layout {
    let visible: Bool
    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize { CGSize(width: 80, height: 40) }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        for child in subviews { child.place(at: .zero, isVisible: visible) }
    }
}

private final class VisibilityPaints { var count = 0 }
private struct VisibilityProbe: _PrimitiveView {
    let paints: VisibilityPaints
    let opacity: Float
    func _makeNode() -> Node { let node = Node(); node.isFocusable = true; return node }
    func _makeLayoutNode() -> LayoutNode? { let layout = LayoutNode(); layout.width = 50; layout.height = 30; return layout }
    func _updateNode(_ node: Node) {
        node.subtreeOpacity = opacity
        node.accessibility = AccessibilitySemantics(.button) { $0.label = "Layout probe" }
        node.updateDraw(identity: opacity) { list, origin in
            paints.count += 1
            list.addRect(UIRect(x: Float(origin.x), y: Float(origin.y), width: 50, height: 30), color: .white)
        }
    }
}
private final class VisibilityFixture: View {
    let paints = VisibilityPaints()
    @State var visible = true
    @State var opacity: Float = 0.6
    var body: some View { VisibilityLayout(visible: visible) { VisibilityProbe(paints: paints, opacity: opacity) } }
}

@Suite("Layout placement visibility", .serialized)
struct CustomLayoutVisibilityTests: GuavaUIComposeSerializedSuite {
    @Test("Both painters omit hidden retained slots, invalidate caches and preserve authored style while focus/capture clear")
    func renderingAndInput() throws { try GlobalTestLock.locked {
        let context = PlatformInputContext()
        try context.withCurrent {
            let fixture = VisibilityFixture(), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: fixture)
            func settle() { graph.recomposer.commitAll(); graph.computeLayout(width: 100, height: 60) }
            func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
            settle(); defer { graph.install(root: EmptyView()) }
            let root = try #require(graph.tree.root)
            let probe = try #require(nodes(root).first { $0.accessibility?.label == "Layout probe" })
            let layered = LayerAwareNodeRenderer()
            let direct = DrawList(), cached = DrawList()
            NodeRenderer().render(root: root, into: direct)
            layered.render(tree: graph.renderTree, into: cached)
            #expect(!direct.vertices.isEmpty && !cached.vertices.isEmpty)
            context.focusChain.focus(probe)
            context.pointerCapture.acquire(probe)
            fixture.visible = false; settle()
            let paints = fixture.paints.count
            let hidden = DrawList(), hiddenCached = DrawList()
            NodeRenderer().render(root: root, into: hidden)
            layered.render(tree: graph.renderTree, into: hiddenCached)
            #expect(hidden.vertices.isEmpty && hiddenCached.vertices.isEmpty && fixture.paints.count == paints)
            #expect(!probe.isLayoutVisible && !probe.acceptsSubtreeInput)
            #expect(context.focusChain.focused == nil && context.pointerCapture.target == nil)
            #expect(AccessibilityTree.snapshot(root: root).isEmpty)
            fixture.opacity = 0.3; settle()
            fixture.visible = true; settle()
            let restored = DrawList(), restoredCached = DrawList()
            NodeRenderer().render(root: root, into: restored)
            layered.render(tree: graph.renderTree, into: restoredCached)
            #expect(!restored.vertices.isEmpty && !restoredCached.vertices.isEmpty)
            #expect(probe.isLayoutVisible && probe.subtreeOpacity == 0.3)
            #expect(nodes(root).contains { $0 === probe })
            #expect(HitTester.hitTest(rootNode: root, point: CGPoint(x: 2, y: 2))?.node === probe)
        }
    } }
}
