import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Lazy grid viewport", .serialized)
struct LazyGridTests {
    @Test("fixed rows find the viewport without scanning all rows")
    func fixedRange() {
        let rows = GridRowHeights.fixed(20)
        #expect(rows.visibleRows(count: 100_000, offset: 300_000, viewportHeight: 60, spacing: 10, overscan: 2) == 9_998..<10_004)
        #expect(rows.totalHeight(rowCount: 100_000, spacing: 10) == 2_999_990)
        #expect(rows.visibleRows(count: 0, offset: 100, viewportHeight: 60, spacing: 10, overscan: 2) == 0..<0)
        let largestRange = GridRowHeights.fixed(1).visibleRows(count: Int.max, offset: .greatestFiniteMagnitude,
                                                              viewportHeight: 1, spacing: 0, overscan: 0)
        #expect(largestRange.upperBound == Int.max)
    }

    @Test("variable rows use prefix offsets including spacing and exact boundaries")
    func variableRange() {
        let rows = GridRowHeights.variable([10, 30, 20, 40])
        rows.validate(rowCount: 4)
        #expect(rows.offset(of: 2, spacing: 5) == 50)
        #expect(rows.totalHeight(rowCount: 4, spacing: 5) == 115)
        #expect(rows.visibleRows(count: 4, offset: 15, viewportHeight: 30, spacing: 5, overscan: 0) == 1..<2)
        #expect(rows.visibleRows(count: 4, offset: 10, viewportHeight: 4, spacing: 5, overscan: 0) == 1..<1)
        #expect(rows.visibleRows(count: 4, offset: 50, viewportHeight: 25, spacing: 5, overscan: 1) == 1..<4)
        #expect(rows.visibleRows(count: 4, offset: 10_000, viewportHeight: 40, spacing: 5, overscan: 0) == 3..<4)
    }

    @Test("nonpositive heights normalize and fixed/variable geometry agrees")
    func normalizedHeights() {
        let rows = GridRowHeights.variable([0, -.infinity, .nan])
        #expect(rows.totalHeight(rowCount: 3, spacing: 2) == 7)
        let fixed = GridRowHeights.fixed(20)
        let variable = GridRowHeights.variable(Array(repeating: 20, count: 100))
        for offset in stride(from: CGFloat.zero, through: 2_900, by: 7) {
            #expect(fixed.visibleRows(count: 100, offset: offset, viewportHeight: 51, spacing: 10, overscan: 2)
                    == variable.visibleRows(count: 100, offset: offset, viewportHeight: 51, spacing: 10, overscan: 2))
        }
    }

    private final class BuildProbe {
        var count = 0
        func cell(_ index: Int) -> some View {
            count += 1
            return Box {}.debugName("lazy-cell-\(index)")
        }
    }

    private struct Harness: View {
        let probe: BuildProbe
        @State var count = 100_000
        @State var offset = CGPoint.zero
        var body: some View {
            LazyGrid(0..<count, id: \.self, columns: 3, rowHeights: .fixed(20),
                     columnSpacing: 6, rowSpacing: 5, overscan: 2, scrollOffset: $offset) { index in
                probe.cell(index)
            }
            .frame(width: 300, height: 100)
        }
    }

    @Test("large collections mount only the viewport and clamp after data shrink")
    func mountedViewport() { GlobalTestLock.locked {
        let probe = BuildProbe()
        let harness = Harness(probe: probe)
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: harness)
        settle(graph)
        #expect(probe.count < 100)
        #expect(mounted(in: graph.tree.root).count <= 24)
        #expect(mounted(in: graph.tree.root).contains { $0.0 == "lazy-cell-0" })
        let initial = mounted(in: graph.tree.root).first { $0.0 == "lazy-cell-9" }?.1
        harness.$offset.wrappedValue = CGPoint(x: 0, y: 25)
        settle(graph)
        #expect(mounted(in: graph.tree.root).first { $0.0 == "lazy-cell-9" }?.1 === initial)
        harness.$offset.wrappedValue = CGPoint(x: 0, y: 200_000)
        settle(graph)
        #expect(mounted(in: graph.tree.root).count <= 30)
        #expect(!mounted(in: graph.tree.root).contains { $0.0 == "lazy-cell-0" })
        harness.$count.wrappedValue = 2
        settle(graph)
        let remaining = mounted(in: graph.tree.root)
        #expect(remaining.count == 2)
        #expect(remaining.allSatisfy { $0.1.absoluteFrame.minY >= 0 && $0.1.absoluteFrame.maxY <= 100 })
        #expect(harness.offset.y == 0)
    } }

    @Test("variable height grid keeps full extent with a partial last row")
    func variableExtent() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: LazyGrid(0..<7, id: \.self, columns: 2,
                                    rowHeights: .variable([15, 35, 25, 45]), rowSpacing: 5, overscan: 0) { index in
            Box {}.debugName("lazy-cell-\(index)")
        }.frame(width: 200, height: 50))
        for _ in 0..<4 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 200, height: 50)
        }
        let cells = mounted(in: graph.tree.root)
        #expect(cells.count == 4)
        let secondRowCell = cells.first { $0.0 == "lazy-cell-2" }?.1
        #expect(secondRowCell?.absoluteFrame.minY == 20)
        #expect(secondRowCell?.frame.height == 35)
        let scroll = descendants(of: graph.tree.root).first { $0.clipsToBounds }
        #expect(scroll?.children.first?.frame.height == 135)
    } }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<4 {
            graph.recomposer.commitAll()
            graph.computeLayout(width: 300, height: 100)
        }
    }

    private func mounted(in root: Node?) -> [(String, Node)] {
        descendants(of: root).compactMap { node in
            guard let name = node.attachments[LayoutDebugAttachmentKey.debugName] as? String,
                  name.hasPrefix("lazy-cell-") else { return nil }
            return (name, node)
        }
    }

    private func descendants(of root: Node?) -> [Node] {
        guard let root else { return [] }
        return [root] + root.children.flatMap { descendants(of: $0) }
    }
}
