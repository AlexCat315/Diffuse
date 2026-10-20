import Testing
@testable import GuavaUIRuntime

@Suite("Linear gradient")
struct LinearGradientTests {
    private let red = Color(r: 1, g: 0, b: 0)
    private let blue = Color(r: 0, g: 0, b: 1)
    private let rect = UIRect(x: 10, y: 20, width: 100, height: 40)

    private func same(_ a: Color, _ b: Color) -> Bool {
        abs(a.r - b.r) < 0.001 && abs(a.g - b.g) < 0.001 && abs(a.b - b.b) < 0.001 && abs(a.a - b.a) < 0.001
    }

    @Test("CSS angles put the start color on the edge the ramp leaves from")
    func angles() {
        let across = UILinearGradient(red, blue, angle: 90)
        #expect(same(across.color(atX: 10, y: 40, in: rect), red))
        #expect(same(across.color(atX: 110, y: 40, in: rect), blue))
        let down = UILinearGradient(red, blue, angle: 180)
        #expect(same(down.color(atX: 60, y: 20, in: rect), red))
        #expect(same(down.color(atX: 60, y: 60, in: rect), blue))
        let diagonal = UILinearGradient(red, blue, angle: 135)
        #expect(same(diagonal.color(atX: 10, y: 20, in: rect), red))
        #expect(same(diagonal.color(atX: 110, y: 60, in: rect), blue))
        let middle = diagonal.color(atX: 60, y: 40, in: rect)
        #expect(abs(middle.r - 0.5) < 0.001 && abs(middle.b - 0.5) < 0.001)
    }

    @Test("Rounded gradient fills keep their coverage fringe and color every vertex by position")
    func drawing() {
        let list = DrawList()
        let gradient = UILinearGradient(red, blue, angle: 90)
        list.addLinearGradient(rect, radius: 8, gradient: gradient)
        #expect(!list.vertices.isEmpty)
        var sawTransparentFringe = false
        for vertex in list.vertices {
            let alpha = vertex.color >> 24
            if alpha == 0 { sawTransparentFringe = true; continue }
            let expected = gradient.color(atX: vertex.posX, y: vertex.posY, in: rect).multipliedAlpha(Float(alpha) / 255)
            #expect(vertex.color == expected.rgba8)
        }
        #expect(sawTransparentFringe)
        // Opacity applies to both stops.
        #expect(gradient.multipliedAlpha(0.5).start.a == 0.5 && gradient.multipliedAlpha(0.5).end.a == 0.5)
    }
}
