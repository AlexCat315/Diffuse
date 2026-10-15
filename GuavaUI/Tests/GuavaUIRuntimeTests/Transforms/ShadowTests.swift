public import Foundation
public import Testing
@testable public import GuavaUIRuntime

@Suite("Scaled surface shadows")
struct ShadowTests {
    private func group(_ frame: CGRect, scale: Float = 1, scalesShadow: Bool = true) -> Node {
        let node = Node()
        node.frame = frame
        node.transform = NodeTransform(scale: scale, anchor: .zero, scalesShadow: scalesShadow)
        return node
    }

    private func reference(for node: Node, shadowScale: Float, paintScale: Float) -> DrawList {
        let bounds = node.absoluteFrame
        let rect = UIRect(x: Float(bounds.minX), y: Float(bounds.minY), width: Float(bounds.width), height: Float(bounds.height))
        let list = DrawList()
        list.addShadow(LayeredShadow(
            ambient: SurfaceShadow(color: .white, offsetX: -2 * shadowScale, offsetY: -4 * shadowScale, blur: 6 * shadowScale),
            key: SurfaceShadow(color: .black, offsetX: 6 * shadowScale, offsetY: 10 * shadowScale, blur: 8 * shadowScale)),
            rect: rect, cornerRadius: 8 * paintScale)
        return list
    }

    private func expectSameGeometry(_ actual: DrawList, _ expected: DrawList) {
        #expect(actual.vertices.count == expected.vertices.count)
        #expect(actual.indices == expected.indices)
        for (actual, expected) in zip(actual.vertices, expected.vertices) {
            #expect(abs(actual.posX - expected.posX) < 0.0001 && abs(actual.posY - expected.posY) < 0.0001)
            #expect(actual.color == expected.color)
        }
    }

    @Test("Ordinary scale changes both shadow layers; lifecycle scale retains their offsets and blur",
          arguments: [true, false])
    func shadowPolicy(scalesShadow: Bool) {
        let root = group(CGRect(x: 0, y: 0, width: 800, height: 600))
        let panel = group(CGRect(x: 100, y: 80, width: 200, height: 100), scale: 0.5, scalesShadow: scalesShadow)
        root.addChild(panel)
        configureShadows(panel)
        let expected = reference(for: panel, shadowScale: scalesShadow ? 0.5 : 1, paintScale: 0.5)
        let direct = DrawList()
        NodeRenderer().render(root: root, into: direct)
        expectSameGeometry(direct, expected)
        let render = RenderTree()
        render.install(rootNode: root)
        let renderer = LayerAwareNodeRenderer()
        for _ in 0..<3 {
            let cached = DrawList()
            renderer.render(tree: render, into: cached)
            expectSameGeometry(cached, expected)
        }
        // Rendering never writes resolved lengths back into authored styles.
        #expect(panel.shadow.offsetY == 10 && panel.shadow.blur == 8)
        #expect(panel.ambientShadow.offsetY == -4 && panel.ambientShadow.blur == 6)
    }

    @Test("Nested ordinary scales accumulate around a lifecycle scale, including through retained caches")
    func nestedScalesAndCache() {
        let root = group(CGRect(x: 0, y: 0, width: 1_000, height: 800))
        let outer = group(CGRect(x: 30, y: 40, width: 300, height: 200), scale: 2)
        let reveal = group(CGRect(x: 20, y: 10, width: 200, height: 100), scale: 0.5, scalesShadow: false)
        let panel = group(CGRect(x: 12, y: 14, width: 100, height: 60), scale: 0.5)
        root.addChild(outer); outer.addChild(reveal); reveal.addChild(panel)
        configureShadows(panel)
        let render = RenderTree()
        render.install(rootNode: root)
        let renderer = LayerAwareNodeRenderer()
        for scalesShadow in [true, false, true] {
            outer.transform.scalesShadow = scalesShadow
            let expected = reference(for: panel, shadowScale: scalesShadow ? 1 : 0.5, paintScale: 0.5)
            for _ in 0..<3 {
                let cached = DrawList()
                renderer.render(tree: render, into: cached)
                expectSameGeometry(cached, expected)
            }
            let direct = DrawList()
            NodeRenderer().render(root: root, into: direct)
            expectSameGeometry(direct, expected)
            #expect(panel.absoluteFrame == CGRect(x: 82, y: 74, width: 50, height: 30))
        }
    }

    private func configureShadows(_ node: Node) {
        node.cornerRadius = 8
        node.ambientShadow = SurfaceShadow(color: .white, offsetX: -2, offsetY: -4, blur: 6)
        node.shadow = SurfaceShadow(color: .black, offsetX: 6, offsetY: 10, blur: 8)
    }

    @Test("A larger inherited shadow brings an offscreen cached leaf back into view")
    func expandedShadowCulling() {
        let root = group(CGRect(x: 0, y: 0, width: 500, height: 400))
        let outer = group(CGRect(x: 0, y: 0, width: 800, height: 400), scale: 2, scalesShadow: false)
        let reveal = group(CGRect(x: 0, y: 0, width: 800, height: 400), scale: 0.5, scalesShadow: false)
        let panel = group(CGRect(x: 510, y: 100, width: 100, height: 60))
        root.addChild(outer); outer.addChild(reveal); reveal.addChild(panel)
        configureShadows(panel)
        let render = RenderTree()
        render.install(rootNode: root)
        let renderer = LayerAwareNodeRenderer()
        for _ in 0..<3 {
            let list = DrawList()
            renderer.render(tree: render, into: list)
            #expect(list.vertices.isEmpty)
        }
        outer.transform.scalesShadow = true
        let visible = DrawList()
        renderer.render(tree: render, into: visible)
        #expect(!visible.vertices.isEmpty)
        #expect(visible.vertices.contains { $0.posX < 500 })
    }
}
