public import Foundation
public import Testing
public import GuavaUIRuntime

@Suite("Scaled content painting")
struct PaintTests {
    @Test("Custom content, its clips and overlay scale with nested translated nodes", arguments: [false, true])
    func customContent(layered: Bool) {
        let root = Node()
        root.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let group = Node()
        group.frame = CGRect(x: 40, y: 20, width: 200, height: 160)
        group.transform = NodeTransform(scale: 0.5)
        root.addChild(group)
        let content = Node()
        content.frame = CGRect(x: 10, y: 20, width: 80, height: 40)
        content.clipsToBounds = true
        content.draw = { list, origin in
            let rect = UIRect(x: Float(origin.x) + 4, y: Float(origin.y) + 6, width: 20, height: 12)
            list.pushClip(rect)
            list.addRect(rect, color: .white)
            list.popClip()
        }
        content.overlayDraw = { list, origin in
            list.addRect(UIRect(x: Float(origin.x) + 30, y: Float(origin.y) + 10, width: 10, height: 8), color: .black)
        }
        group.addChild(content)
        let render = RenderTree()
        render.install(rootNode: root)
        let renderer = LayerAwareNodeRenderer()
        for _ in 0..<3 {
            let list = DrawList()
            if layered { renderer.render(tree: render, into: list) }
            else { NodeRenderer().render(root: root, into: list) }
            #expect(content.absoluteFrame == CGRect(x: 45, y: 30, width: 40, height: 20))
            let whites = list.vertices.filter { $0.color == Color.white.rgba8 }
            #expect(whites.count == 4)
            #expect(whites.map(\.posX).min() == 47 && whites.map(\.posX).max() == 57)
            #expect(whites.map(\.posY).min() == 33 && whites.map(\.posY).max() == 39)
            let blacks = list.vertices.filter { $0.color == Color.black.rgba8 }
            #expect(blacks.map(\.posX).min() == 60 && blacks.map(\.posX).max() == 65)
            #expect(blacks.map(\.posY).min() == 35 && blacks.map(\.posY).max() == 39)
            #expect(list.batches.first?.scissor == UIRect(x: 47, y: 33, width: 10, height: 6))
            #expect(list.batches.last?.scissor == UIRect(x: 45, y: 30, width: 40, height: 20))
        }
    }
}
