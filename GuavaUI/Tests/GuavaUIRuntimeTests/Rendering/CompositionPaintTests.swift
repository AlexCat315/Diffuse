import Foundation
import Testing
@testable import GuavaUIRuntime

@Suite("Composition value paint caching")
struct CompositionPaintTests {
    @Test("Changing an inherited value invalidates custom painters but retains a locally overridden cache")
    func inheritedValueChanges() {
        let color = CompositionLocal<Color>(defaultValue: .white)
        let root = Node(), inherited = Node(), pinned = Node()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        inherited.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        pinned.frame = CGRect(x: 50, y: 0, width: 40, height: 40)
        root.addChild(inherited); root.addChild(pinned)
        root.setCompositionValue(color, Color.black)
        pinned.setCompositionValue(color, Color.white)
        var inheritedDraws = 0, pinnedDraws = 0
        inherited.draw = { [weak inherited] list, _ in
            inheritedDraws += 1
            list.addRect(UIRect(x: 0, y: 0, width: 40, height: 40), color: inherited!.compositionValue(of: color))
        }
        pinned.draw = { [weak pinned] list, _ in
            pinnedDraws += 1
            list.addRect(UIRect(x: 50, y: 0, width: 40, height: 40), color: pinned!.compositionValue(of: color))
        }
        let tree = RenderTree(), renderer = LayerAwareNodeRenderer()
        tree.install(rootNode: root)
        for _ in 0..<3 { renderer.render(tree: tree, into: DrawList()) }
        #expect(inheritedDraws == 1 && pinnedDraws == 1)
        root.setCompositionValue(color, Color.white)
        let updated = DrawList()
        renderer.render(tree: tree, into: updated)
        #expect(updated.vertices.allSatisfy { $0.color == Color.white.rgba8 })
        #expect(inheritedDraws == 2 && pinnedDraws == 1)
    }
}
