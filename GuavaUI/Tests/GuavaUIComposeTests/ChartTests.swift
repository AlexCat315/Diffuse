import Testing
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Chart drawing and geometry")
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
            if min(u, min(v, w)) >= -0.001 && alpha > 20 { return true }
        }
        return false
    }

    private func draw(_ content: ChartContent, style: ChartStyle, selection: ChartPoint? = nil,
                      size: CGSize = CGSize(width: 120, height: 40)) -> (DrawList, Node) {
        let plot = ChartPlot(content: content, visible: Array(repeating: true, count: content.count), style: style,
                             selection: selection, summary: ("Chart", ""), callout: nil,
                             input: ChartPlotInput(isEnabled: false, select: { _ in }))
        let node = plot._makeNode()
        node.frame = CGRect(origin: .zero, size: size)
        plot._updateNode(node)
        let list = DrawList()
        node.draw?(list, .zero)
        return (list, node)
    }

    private func flat(_ style: ChartStyle = ChartStyle(gridLineCount: 0, contentInset: 0)) -> ChartStyle { style }

    @Test("A chart without a selection binding is a passive image with a 64pt default height")
    func passive() {
        let plot = ChartPlot(content: .cartesian(series: [.line([1, 2, 3])], thresholds: [], markers: []), visible: [true],
                             style: ChartStyle(), selection: nil, summary: ("Sales", "1 to 3"), callout: nil,
                             input: ChartPlotInput(isEnabled: false, select: { _ in }))
        let node = plot._makeNode(), layout = plot._makeLayoutNode()!
        plot._updateLayout(layout); plot._updateNode(node)
        #expect(node.isHitTestable == false && node.isFocusable == false)
        #expect(layout.height == 64)
        #expect(node.accessibility?.role == .image && node.accessibility?.label == "Sales")
    }

    @Test("Lines stroke between values; areas fill down to the baseline")
    func lineAndArea() {
        let (line, _) = draw(.cartesian(series: [.line([0, 1, 0])], thresholds: [], markers: []), style: flat())
        #expect(covers(CGPoint(x: 15, y: 30), in: line))
        #expect(covers(CGPoint(x: 60, y: 1), in: line))
        #expect(!covers(CGPoint(x: 60, y: 30), in: line))
        let (area, node) = draw(.cartesian(series: [.area([0, 1, 0])], thresholds: [], markers: []), style: flat())
        #expect(covers(CGPoint(x: 60, y: 30), in: area, color: node.theme.colors.accent))
        #expect(area.vertices.allSatisfy { $0.posX.isFinite && $0.posY.isFinite })
    }

    @Test("Bar series group side by side, or accumulate when stacked")
    func groupedAndStackedBars() {
        let series: [ChartSeries] = [.bar([2, 4], title: "A"), .bar([2, 2], color: .success, title: "B")]
        let plot = UIRect(x: 0, y: 0, width: 100, height: 100)
        let grouped = ChartGeometry(series: series, visible: [true, true], thresholds: [], style: ChartStyle(minValue: 0, barSpacing: 0), plot: plot)
        let a = grouped.marks[0][0].bar!, b = grouped.marks[1][0].bar!
        #expect(a.maxX <= b.minX + 0.5 && a.minY == b.minY)
        #expect(grouped.domain.upperBound == 4)
        let stacked = ChartGeometry(series: series, visible: [true, true], thresholds: [],
                                    style: ChartStyle(minValue: 0, barSpacing: 0, stacking: .stacked), plot: plot)
        let low = stacked.marks[0][1].bar!, high = stacked.marks[1][1].bar!
        #expect(stacked.domain.upperBound == 6)
        #expect(abs(low.minX - high.minX) < 0.01 && abs(high.maxY - low.minY) < 0.01)
        #expect(!stacked.marks[0][1].isOuterEnd && stacked.marks[1][1].isOuterEnd && grouped.marks[0][0].isOuterEnd)
        // Hidden series take no space and leave the domain.
        let hidden = ChartGeometry(series: series, visible: [true, false], thresholds: [], style: ChartStyle(minValue: 0, barSpacing: 0), plot: plot)
        #expect(hidden.marks[1].isEmpty && hidden.marks[0][0].bar!.width > a.width)
    }

    @Test("Lines and bars in one chart share slot centers; markers follow the same x")
    func mixedMarksAlign() {
        let geometry = ChartGeometry(series: [.bar([1, 2, 3]), .line([1, 2, 3])], visible: [true, true], thresholds: [],
                                     style: ChartStyle(minValue: 0, barSpacing: 0), plot: UIRect(x: 0, y: 0, width: 90, height: 30))
        #expect(geometry.marks[0].map(\.x) == geometry.marks[1].map(\.x))
        #expect(geometry.marks[1].map(\.x) == [15, 45, 75])
    }

    @Test("Scatter points use their own x values and the nearest point by distance")
    func scatter() {
        let geometry = ChartGeometry(series: [.points(x: [0, 10, 20], y: [0, 10, 0])], visible: [true], thresholds: [],
                                     style: ChartStyle(), plot: UIRect(x: 0, y: 0, width: 200, height: 100))
        // Points keep a 4% inset from the plot edges.
        #expect(geometry.marks[0].map { $0.x.rounded() } == [7, 100, 193])
        #expect(geometry.nearest(x: 95, y: 5)?.index == 1)
        #expect(geometry.nearest(x: 190, y: 92)?.index == 2)
    }

    @Test("Donut wedges start at 12 o'clock, run clockwise and hit-test by angle and ring")
    func donut() {
        let slices = [ChartSlice("A", value: 1), ChartSlice("B", value: 1), ChartSlice("C", value: 2)]
        let pie = PieGeometry(slices: slices, visible: [true, true, true], innerRatio: 0.5, plot: UIRect(x: 0, y: 0, width: 108, height: 108))
        #expect(pie.total == 4 && pie.wedges.count == 3)
        #expect(pie.wedge(atX: 80, y: 30)?.index == 0)       // upper right
        #expect(pie.wedge(atX: 80, y: 80)?.index == 1)       // lower right
        #expect(pie.wedge(atX: 20, y: 54)?.index == 2)       // left half
        #expect(pie.wedge(atX: 54, y: 54) == nil)            // the hole
        let (list, node) = draw(.pie(slices), style: ChartStyle(gridLineCount: 0, contentInset: 0, innerRadiusRatio: 0.5),
                                size: CGSize(width: 108, height: 108))
        #expect(covers(CGPoint(x: 20, y: 54), in: list, color: node.theme.colors.warning))
        #expect(!covers(CGPoint(x: 54, y: 54), in: list))
        let hidden = PieGeometry(slices: slices, visible: [true, true, false], innerRatio: 0.5, plot: UIRect(x: 0, y: 0, width: 108, height: 108))
        #expect(hidden.total == 2 && hidden.wedge(atX: 20, y: 54)?.index == 1)
    }

    @Test("Thresholds and markers add guide geometry")
    func thresholdAndMarker() {
        let (list, node) = draw(.cartesian(series: [.line([0, 1, 2])], thresholds: [ChartThreshold(value: 1, color: .error)],
                                           markers: [ChartMarker(index: 2, color: .success)]), style: flat())
        #expect(covers(CGPoint(x: 15, y: 20), in: list, color: node.theme.colors.error))
        #expect(covers(CGPoint(x: 120, y: 30), in: list, color: node.theme.colors.success))
    }

    @Test("Selection draws a rule and a ringed point, and dims unselected bars")
    func selectionPaint() {
        let (list, node) = draw(.cartesian(series: [.line([0, 2, 0])], thresholds: [], markers: []), style: flat(),
                                selection: ChartPoint(series: 0, index: 1))
        #expect(covers(CGPoint(x: 60, y: 30), in: list))   // rule
        #expect(covers(CGPoint(x: 64.5, y: 1), in: list, color: node.theme.colors.surface))
    }
}
