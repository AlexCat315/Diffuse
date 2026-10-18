import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Chart primitives")
struct ChartTests {
    /// Test the rendered stroke rather than a particular tessellation budget.
    private func covers(_ point: CGPoint, in list: DrawList, color: Color? = nil) -> Bool {
        for start in stride(from: 0, to: list.indices.count, by: 3) {
            let vertices = (0..<3).map { list.vertices[Int(list.indices[start + $0])] }
            if let color, vertices[0].color & 0x00FF_FFFF != color.rgba8 & 0x00FF_FFFF { continue }
            let a = vertices[0], b = vertices[1], c = vertices[2]
            let x = Float(point.x), y = Float(point.y)
            let denominator = (b.posY - c.posY) * (a.posX - c.posX) + (c.posX - b.posX) * (a.posY - c.posY)
            guard abs(denominator) > 0.0001 else { continue }
            let u = ((b.posY - c.posY) * (x - c.posX) + (c.posX - b.posX) * (y - c.posY)) / denominator
            let v = ((c.posY - a.posY) * (x - c.posX) + (a.posX - c.posX) * (y - c.posY)) / denominator
            let w = 1 - u - v
            let alpha = u * Float(a.color >> 24) + v * Float(b.color >> 24) + w * Float(c.color >> 24)
            if min(u, min(v, w)) >= -0.001 && alpha > 127 { return true }
        }
        return false
    }

    @Test("MonitorChart materialises as a passive primitive with default height")
    func materialisesPassivePrimitive() {
        let chart = MonitorChart(values: [1, 2, 3])
        let node = chart._makeNode()
        let layout = chart._makeLayoutNode()

        #expect(node.isHitTestable == false)
        #expect(layout?.height == 64)
    }

    @Test("Line chart emits line geometry")
    func lineChartEmitsGeometry() {
        let chart = MonitorChart(values: [0, 1, 0],
                                 mode: .line,
                                 style: ChartStyle(gridLineCount: 0,
                                                   contentInset: 0))
        let node = chart._makeNode()
        node.frame = CGRect(x: 0, y: 0, width: 120, height: 40)
        chart._updateNode(node)

        let list = DrawList()
        node.draw?(list, .zero)

        #expect(covers(CGPoint(x: 15, y: 30), in: list))
        #expect(covers(CGPoint(x: 60, y: 0), in: list))
        #expect(covers(CGPoint(x: 105, y: 30), in: list))
        #expect(!covers(CGPoint(x: 60, y: 30), in: list))
        #expect(list.vertices.allSatisfy { $0.posX.isFinite && $0.posY.isFinite })
    }

    @Test("Bar chart emits one quad per sample")
    func barChartEmitsGeometry() {
        let chart = MonitorChart(values: [1, 2, 3],
                                 mode: .bar,
                                 style: ChartStyle(minValue: 0,
                                                   gridLineCount: 0,
                                                   barSpacing: 0,
                                                   contentInset: 0))
        let node = chart._makeNode()
        node.frame = CGRect(x: 0, y: 0, width: 120, height: 40)
        chart._updateNode(node)

        let list = DrawList()
        node.draw?(list, .zero)

        #expect(list.vertices.count == 12)
        #expect(list.indices.count == 18)
    }

    @Test("Thresholds and markers add guide geometry")
    func thresholdAndMarkerEmitGuideGeometry() {
        let chart = MonitorChart(values: [0, 1, 2],
                                 threshold: ChartThreshold(value: 1, color: .error),
                                 marker: ChartMarker(index: 2, color: .success),
                                 style: ChartStyle(gridLineCount: 0,
                                                   contentInset: 0))
        let node = chart._makeNode()
        node.frame = CGRect(x: 0, y: 0, width: 120, height: 40)
        chart._updateNode(node)

        let list = DrawList()
        node.draw?(list, .zero)

        #expect(covers(CGPoint(x: 15, y: 20), in: list, color: node.theme.colors.error))
        #expect(covers(CGPoint(x: 105, y: 20), in: list, color: node.theme.colors.error))
        #expect(covers(CGPoint(x: 120, y: 30), in: list, color: node.theme.colors.success))
        #expect(!covers(CGPoint(x: 80, y: 30), in: list, color: node.theme.colors.error))
    }
}
