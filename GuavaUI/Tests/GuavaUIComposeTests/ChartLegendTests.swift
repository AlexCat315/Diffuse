import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Chart legend", .serialized)
struct ChartLegendTests {
    @Test("legend items share a row at wide widths and wrap at narrow widths")
    func wrapping() { GlobalTestLock.locked {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = previous }
        let items = [
            ChartLegendItem("Revenue", color: .accent),
            ChartLegendItem("Signups", color: .success),
            ChartLegendItem("Conversion", color: .warning),
            ChartLegendItem("Latency", color: .info)
        ]
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: ChartLegend(items: items).frame(width: 220).debugName("legend-narrow"))
        graph.computeLayout(width: 220, height: 120)
        let narrow = legendItems(in: graph.tree.root)
        #expect(narrow.count == 4)
        let firstY = narrow[0].frame.minY
        #expect(narrow.contains { $0.frame.minY > firstY })
        #expect(narrow[0].accessibility?.label == "Revenue")

        graph.install(root: ChartLegend(items: items).frame(width: 600).debugName("legend-wide"))
        graph.computeLayout(width: 600, height: 120)
        let wide = legendItems(in: graph.tree.root)
        #expect(wide.count == 4)
        #expect(Set(wide.map { $0.frame.minY }).count == 1)
    } }

    @Test("series initializer keeps titled series and drops untitled ones")
    func seriesProjection() { GlobalTestLock.locked {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = previous }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: ChartLegend(series: [
            ChartSeries.line([1, 2, 3], color: .accent, title: "Revenue"),
            ChartSeries.line([2, 3, 4], color: .success, title: "  "),
            ChartSeries.bar([3, 4, 5], color: .warning, title: "Signups")
        ]).frame(width: 600))
        graph.computeLayout(width: 600, height: 80)
        let items = legendItems(in: graph.tree.root)
        #expect(items.count == 2)
        #expect(items[0].accessibility?.label == "Revenue")
        #expect(items[1].accessibility?.label == "Signups")
    } }

    @Test("RTL legends start at the trailing edge")
    func rightToLeft() { GlobalTestLock.locked {
        let previous = TextEnvironmentHolder.current
        TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = previous }
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: ChartLegend(items: [
            ChartLegendItem("Revenue", color: .accent),
            ChartLegendItem("Signups", color: .success)
        ]).layoutDirection(.rtl).frame(width: 600))
        graph.computeLayout(width: 600, height: 80)
        let items = legendItems(in: graph.tree.root)
        #expect(items.count == 2)
        #expect(items[0].frame.minX > items[1].frame.minX)
        #expect(items[0].frame.maxX == 600)
    } }

    private func legendItems(in root: Node?) -> [Node] {
        guard let root else { return [] }
        var result: [Node] = []
        if let name = root.attachments[LayoutDebugAttachmentKey.debugName] as? String,
           name.hasPrefix("chart-legend-item-") {
            result.append(root)
        }
        for child in root.children { result.append(contentsOf: legendItems(in: child)) }
        return result.sorted {
            let lhs = ($0.attachments[LayoutDebugAttachmentKey.debugName] as? String) ?? ""
            let rhs = ($1.attachments[LayoutDebugAttachmentKey.debugName] as? String) ?? ""
            return lhs < rhs
        }
    }
}
