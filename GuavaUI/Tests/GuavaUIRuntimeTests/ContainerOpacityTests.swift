import Foundation
import Testing
import GuavaUIRuntime

@Suite("Container opacity")
struct ContainerOpacityTests {
    @Test("direct and cached rendering multiply nested opacity for descendants")
    func descendantOpacity() {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        root.opacity = 0.5
        let child = Node()
        child.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        child.backgroundColor = Color(r: 1, g: 0, b: 0)
        child.opacity = 0.5
        root.addChild(child)
        let direct = DrawList()
        NodeRenderer().render(root: root, into: direct)
        #expect(direct.vertices.allSatisfy { $0.color >> 24 == 64 })
        #expect(!direct.vertices.isEmpty)

        let renderTree = RenderTree()
        renderTree.install(rootNode: root)
        let renderer = LayerAwareNodeRenderer()
        for _ in 0..<3 {
            let cached = DrawList()
            renderer.render(tree: renderTree, into: cached)
            #expect(cached.vertices.map(\.color) == direct.vertices.map(\.color))
        }
        root.opacity = 1
        let changed = DrawList()
        renderer.render(tree: renderTree, into: changed)
        #expect(changed.vertices.allSatisfy { $0.color >> 24 == 128 })
    }
}
