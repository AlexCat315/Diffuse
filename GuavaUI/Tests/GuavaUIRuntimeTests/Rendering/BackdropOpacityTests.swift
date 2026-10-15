import Foundation
import Testing
@testable import GuavaUIRuntime

@Suite("Backdrop opacity")
struct BackdropOpacityTests {
    @Test("Frost follows nested opacity through cached and scaled rendering")
    func nestedOpacity() throws {
        let root = Node(), group = Node(), panel = Node()
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        root.backgroundColor = .black
        root.addChild(group)
        group.frame = root.frame
        group.addChild(panel)
        panel.frame = CGRect(x: 20, y: 20, width: 100, height: 80)
        panel.backgroundColor = Color(r: 1, g: 1, b: 1, a: 0.1)
        panel.backdropBlur = 12
        panel.opacity = 0.5
        panel.subtreeOpacity = 0.5
        let renderTree = RenderTree()
        renderTree.install(rootNode: root)
        let renderer = LayerAwareNodeRenderer()
        for opacity: Float in [0, 0.25, 0.25, 1, 0] {
            group.opacity = opacity
            group.transform = NodeTransform(scale: opacity == 0.25 ? 0.94 : 1)
            // Render twice, including a stable cache reuse at each value.
            for _ in 0..<2 {
                let direct = DrawList(), cached = DrawList()
                NodeRenderer().render(root: root, into: direct)
                renderer.render(tree: renderTree, into: cached)
                let directFrost = try #require(direct.batches.compactMap(\.backdrop).first)
                let cachedFrost = try #require(cached.batches.compactMap(\.backdrop).first)
                #expect(abs(directFrost.opacity - opacity * 0.25) < 0.0001)
                #expect(cachedFrost == directFrost)
                #expect(direct.vertices.first?.color == Color.black.rgba8)
                #expect(cached.vertices.first?.color == Color.black.rgba8)
            }
        }
    }

    @Test("A scaled custom painter preserves its backdrop opacity")
    func customPaint() throws {
        let root = Node(), panel = Node()
        root.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        root.addChild(panel)
        panel.frame = root.frame
        panel.transform = NodeTransform(scale: 0.94)
        panel.draw = { list, _ in
            list.beginBackdrop(UIBackdrop(rect: UIRect(x: 10, y: 10, width: 80, height: 60), opacity: 0.3))
            list.addRect(UIRect(x: 10, y: 10, width: 80, height: 60), color: .white)
        }
        let list = DrawList()
        NodeRenderer().render(root: root, into: list)
        let frost = try #require(list.batches.first?.backdrop)
        #expect(frost.opacity == 0.3)
        #expect(abs(frost.rect.width - 75.2) < 0.001)
    }
}
