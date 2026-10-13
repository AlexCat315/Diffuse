import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
@testable import GuavaUIRuntime

/// How a shadow layer and a rim light become geometry. These assert the two
/// properties a floating panel depends on: the layers really are separate and
/// ordered, and the rim really is a thin line at the top edge.
@Suite("Surface painting")
struct SurfacePaintingTests {

    private func node(_ frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 40)) -> Node {
        let node = Node()
        node.frame = frame
        return node
    }

    private func shadow(_ alpha: Float, offsetY: Float, blur: Float) -> SurfaceShadow {
        SurfaceShadow(color: Color(r: 0, g: 0, b: 0, a: alpha), offsetY: offsetY, blur: blur)
    }

    private func render(_ node: Node) -> DrawList {
        let list = DrawList()
        NodeRenderer().render(root: node, into: list)
        return list
    }

    /// Shadow steps are rounded rects whose tessellation depends on the radius,
    /// so geometry is compared against the span it must cover rather than
    /// against exact corner positions.
    private func spanX(_ list: DrawList) -> Float {
        (list.vertices.map(\.posX).max() ?? 0) - (list.vertices.map(\.posX).min() ?? 0)
    }

    private func top(_ list: DrawList) -> Float { list.vertices.map(\.posY).min() ?? 0 }

    private func alphaRange(_ list: DrawList) -> ClosedRange<Float> {
        let values = list.vertices.map { Float(($0.color >> 24) & 0xFF) / 255 }
        return (values.min() ?? 0)...(values.max() ?? 0)
    }

    @Test("A floating node paints its ambient halo under its key shadow")
    func layeredShadowOrder() {
        let halo = node()
        halo.ambientShadow = shadow(1, offsetY: 3, blur: 20)
        let contact = node()
        contact.shadow = shadow(1, offsetY: 6, blur: 8)

        let both = node()
        both.ambientShadow = halo.ambientShadow
        both.shadow = contact.shadow

        let ambient = render(halo), key = render(contact), layered = render(both)
        // Both layers, concatenated: the halo has to go down first.
        #expect(layered.vertices.count == ambient.vertices.count + key.vertices.count)
        #expect(layered.vertices.prefix(ambient.vertices.count).map(\.posX)
                == ambient.vertices.map(\.posX))

        // Only quantized visible steps remain. The ambient layer still reaches
        // farther, and each stays inside its authored blur's maximum extent.
        #expect(spanX(ambient) > spanX(key))
        #expect(spanX(key) > 100 && spanX(key) <= 116 + 1)
        #expect(spanX(ambient) <= 140 + 1)
        // Offsets translate the surviving geometry without changing the blur.
        let unshiftedHalo = node(), unshiftedContact = node()
        unshiftedHalo.ambientShadow = shadow(1, offsetY: 0, blur: 20)
        unshiftedContact.shadow = shadow(1, offsetY: 0, blur: 8)
        #expect(abs(top(ambient) - top(render(unshiftedHalo)) - 3) < 0.01)
        #expect(abs(top(key) - top(render(unshiftedContact)) - 6) < 0.01)
    }

    @Test("The ambient halo is broader and fainter than the key shadow under it")
    func ambientIsBroaderAndFainter() {
        let halo = node()
        halo.ambientShadow = shadow(0.3, offsetY: 3, blur: 20)
        let contact = node()
        contact.shadow = shadow(0.9, offsetY: 6, blur: 8)

        let ambient = render(halo), key = render(contact)
        #expect(spanX(ambient) > spanX(key))
        // Densest step of each layer: the one hugging the surface.
        #expect(alphaRange(ambient).upperBound < alphaRange(key).upperBound)
        // The falloff spans the blur: the outermost fringe is the faintest
        // thing the layer paints.
        #expect(alphaRange(ambient).lowerBound < alphaRange(ambient).upperBound)
    }

    @Test("A surface with one shadow layer still paints one")
    func singleLayerStaysSingle() {
        let node = node()
        node.shadow = shadow(1, offsetY: 1, blur: 2)

        let list = render(node)
        // One layer: the same geometry the layered render appends after the
        // halo, not twice the geometry.
        let layered = node
        layered.ambientShadow = shadow(1, offsetY: 3, blur: 20)
        let halo = render(layered)
        #expect(list.vertices.count < halo.vertices.count)
        // It spreads past the node (100 wide) but nowhere near as far as a
        // halo would.
        #expect(spanX(list) > 100)
        #expect(spanX(list) < spanX(halo))
    }

    @Test("The rim light is a thin line at the top, inside the corner radius")
    func highlightGeometry() {
        let node = node()
        node.cornerRadius = 6
        node.highlight = SurfaceHighlight(color: Color(r: 1, g: 1, b: 1, a: 0.5))

        let list = render(node)
        #expect(list.vertices.count == 4)
        #expect(list.vertices[0].posX == 6)
        #expect(list.vertices[0].posY == 0)
        #expect(list.vertices[2].posX == 94)
        #expect(list.vertices[2].posY == 1)
    }

    @Test("Without a rim light nothing is painted")
    func emptyHighlightPaintsNothing() {
        let node = node()
        node.cornerRadius = 6

        let list = render(node)
        #expect(list.vertices.isEmpty)
    }

    @Test("The rim light sits above children, which cannot cover the edge")
    func highlightPaintsAfterChildren() {
        let node = node()
        node.cornerRadius = 6
        node.highlight = SurfaceHighlight(color: Color(r: 1, g: 1, b: 1, a: 0.5))
        let child = Node()
        child.frame = CGRect(x: 10, y: 0, width: 20, height: 10)
        child.backgroundColor = Color(r: 1, g: 0, b: 0, a: 1)
        node.addChild(child)

        let list = render(node)
        #expect(list.vertices.count == 8)
        #expect(list.vertices[4].posX == 6)
        #expect(list.vertices[6].posY == 1)
    }

    @Test("Opacity dims the rim light with the surface")
    func highlightFollowsOpacity() {
        let node = node()
        node.cornerRadius = 6
        node.opacity = 0.5
        node.highlight = SurfaceHighlight(color: Color(r: 1, g: 1, b: 1, a: 0.5))

        let list = render(node)
        #expect(abs(alphaRange(list).upperBound - 0.25) < 0.02)
    }
}
