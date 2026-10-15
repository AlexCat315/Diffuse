import Foundation
import Testing
@testable import GuavaUIRuntime

/// The renderer has to carry a node's frame-level reveal all the way to the
/// frame's `DrawList`, including when the node sits inside a cached layer that
/// gets replayed instead of re-recorded.
@Suite("Frame reveal requests")
struct RevealRequestTests {
    private func reveal(_ sequence: UInt64 = 1, radius: Float = 40) -> UIReveal {
        UIReveal(sequence: sequence, centerX: 12, centerY: 34, radius: radius)
    }

    @Test("The legacy walker raises the request")
    func directRenderer() throws {
        let root = Node(), surface = Node()
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        root.addChild(surface)
        surface.requestReveal(reveal())
        let list = DrawList()
        NodeRenderer().render(root: root, into: list)
        #expect(list.reveal == reveal())
    }

    @Test("An inline node's request reaches the frame list")
    func inlineNode() throws {
        let root = Node(), surface = Node()
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        root.addChild(surface)
        surface.requestReveal(reveal())
        let tree = RenderTree()
        tree.install(rootNode: root)
        let list = DrawList()
        LayerAwareNodeRenderer().render(tree: tree, into: list)
        #expect(list.reveal == reveal())
    }

    @Test("A request survives a cached layer being replayed")
    func cachedLayer() throws {
        // A painter makes the node a layer root, which is the case that records
        // into its own cache and appends that instead of re-recording.
        let root = Node(), surface = Node()
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        surface.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        surface.draw = { list, _ in list.addRect(UIRect(x: 0, y: 0, width: 8, height: 8), color: .white) }
        root.addChild(surface)
        let tree = RenderTree()
        tree.install(rootNode: root)
        let renderer = LayerAwareNodeRenderer()
        for radius: Float in [40, 90] {
            surface.requestReveal(reveal(radius: radius))
            let list = DrawList()
            renderer.render(tree: tree, into: list)
            #expect(list.reveal == reveal(radius: radius))
        }
        // A stable frame with no request must not inherit the previous one:
        // a replayed layer still carries whatever it last recorded.
        surface.requestReveal(nil)
        let list = DrawList()
        renderer.render(tree: tree, into: list)
        #expect(list.reveal == nil)
    }

    @Test("A run is keyed by sequence so one frame is retained per run")
    func sequenceKeysTheRun() {
        let first = reveal(1, radius: 10)
        let second = reveal(2, radius: 10)
        #expect(first != second)
        #expect(first.sequence == 1)
        #expect(reveal().isVisible)
        var invisible = reveal()
        invisible.radius = 0
        #expect(!invisible.isVisible)
    }

    @Test("A reset frame carries no request")
    func resetDropsTheRequest() {
        let list = DrawList()
        list.beginReveal(reveal())
        #expect(list.reveal == reveal())
        list.reset()
        #expect(list.reveal == nil)
    }
}