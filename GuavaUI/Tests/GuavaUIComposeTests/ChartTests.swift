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

        #expect(list.vertices.count == 8)
        #expect(list.indices.count == 12)
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
                                 threshold: ChartThreshold(value: 1),
                                 marker: ChartMarker(index: 2),
                                 style: ChartStyle(gridLineCount: 0,
                                                   contentInset: 0))
        let node = chart._makeNode()
        node.frame = CGRect(x: 0, y: 0, width: 120, height: 40)
        chart._updateNode(node)

        let list = DrawList()
        node.draw?(list, .zero)

        #expect(list.vertices.count == 16)
        #expect(list.indices.count == 24)
    }
}
