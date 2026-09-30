import Foundation
import Testing
@testable import GuavaUIRuntime

@Suite("Surface rendering")
struct SurfaceRenderingTests {
    @Test("transparent rounded borders do not fill the control interior")
    func borderLeavesCenterClear() {
        let node = Node()
        node.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        node.borderColor = .white
        node.borderWidth = 1
        node.cornerRadius = 6
        let reference = DrawList()
        NodeRenderer().render(root: node, into: reference)
        let tree = RenderTree()
        tree.install(rootNode: node)
        let cached = DrawList()
        LayerAwareNodeRenderer().render(tree: tree, into: cached)
        for list in [reference, cached] {
            #expect(!contains(x: 50, y: 20, in: list))
            #expect(contains(x: 0.5, y: 20, in: list))
            #expect(!contains(x: 0.2, y: 0.2, in: list))
        }
        #expect(reference.indices == cached.indices)
    }

    @Test("monospaced fonts give code characters equal advances")
    func realMonospacedMetrics() throws {
        let atlas = FontAtlas()
        let resolver = TextFontResolver(primaryFontName: SystemFontDefaults.primaryFontName, atlas: atlas)
        let glyphs = resolver.shape(text: "ilW0", font: .monospaced(size: 14))
        #expect(glyphs.count == 4)
        let advance = try #require(glyphs.first?.xAdvance)
        #expect(glyphs.allSatisfy { abs($0.xAdvance - advance) < 0.01 })
        #expect(Font.monospaced(size: 14) != Font.system(size: 14))
    }

    private func contains(x: Float, y: Float, in list: DrawList) -> Bool {
        for index in stride(from: 0, to: list.indices.count, by: 3) {
            let a = list.vertices[Int(list.indices[index])]
            let b = list.vertices[Int(list.indices[index + 1])]
            let c = list.vertices[Int(list.indices[index + 2])]
            func cross(_ p: UIVertex, _ q: UIVertex, _ px: Float, _ py: Float) -> Float {
                (q.posX - p.posX) * (py - p.posY) - (q.posY - p.posY) * (px - p.posX)
            }
            guard abs(cross(a, b, c.posX, c.posY)) > 0.00001 else { continue }
            let edges = [cross(a, b, x, y), cross(b, c, x, y), cross(c, a, x, y)]
            if edges.allSatisfy({ $0 >= 0 }) || edges.allSatisfy({ $0 <= 0 }) { return true }
        }
        return false
    }
}
