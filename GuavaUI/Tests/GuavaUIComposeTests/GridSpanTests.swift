import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Grid spans and two-axis LazyGrid windows", .serialized)
@MainActor
struct GridSpanTests: GuavaUIComposeSerializedSuite {
    @Test("Row-major placement skips occupied cells and wraps cells that do not fit")
    func placement() throws {
        let plan = GridSpanPlacement(spans: [GridSpan(columns: 2), GridSpan(rows: 2), GridSpan(), GridSpan(columns: 3), GridSpan()],
                                     columnCount: 3)
        #expect(plan.cells.map { [$0.row, $0.column] } == [[0, 0], [0, 2], [1, 0], [2, 0], [3, 0]])
        #expect(plan.rowCount == 4)
        let clamped = GridSpanPlacement(spans: [GridSpan(columns: 9)], columnCount: 2)
        #expect(clamped.cells[0].span.columns == 2)
        let heights = plan.rowHeights(itemHeights: [20, 70, 20, 30, 10], rowSpacing: 10)
        // The two-row cell needs 70: rows 0 and 1 (20 + 10 + 20) grow the last spanned row by 20.
        #expect(heights == [20, 40, 30, 10])
    }

    @Test("Spanning children get the combined width and height, mirrored in RTL")
    func layoutGeometry() throws {
        try InteractiveScene.run(width: 400, height: 400) { scene in
            for rtl in [false, true] {
                scene.install(Grid(columns: [.flexible(), .flexible(), .flexible()], columnSpacing: 10, rowSpacing: 10) {
                    Box {}.frame(height: 20).gridCellSpan(columns: 2).debugName("wide")
                    Box {}.frame(height: 50).gridCellSpan(rows: 2).debugName("tall")
                    Box {}.frame(height: 20).debugName("a")
                    Box {}.frame(height: 20).debugName("b")
                }.frame(width: 320).layoutDirection(rtl ? .rtl : .ltr))
                let wide = try #require(scene.named("wide")), tall = try #require(scene.named("tall")), a = try #require(scene.named("a")), b = try #require(scene.named("b"))
                // Cells keep their intrinsic width; placement uses the spanned tracks.
                if !rtl { #expect(abs(tall.absoluteFrame.minX - wide.absoluteFrame.minX - 220) < 1) }
                #expect(abs(a.absoluteFrame.minY - wide.absoluteFrame.maxY - 10) < 1)
                #expect(abs(b.absoluteFrame.minY - a.absoluteFrame.minY) < 1)
                if rtl { #expect(tall.absoluteFrame.maxX < wide.absoluteFrame.minX) }
                else { #expect(tall.absoluteFrame.minX > wide.absoluteFrame.maxX) }
            }
        }
    }

    @Test("LazyGrid packs spans per row and windows columns of a wide grid")
    func lazyRows() throws {
        let rows = LazyGridRows(itemCount: 6, columns: 3, spans: [2, 1, 3, 1, 2, 5])
        #expect(rows.count == 4)
        #expect(rows.items(inRow: 0) == 0..<2)
        #expect(rows.items(inRow: 1) == 2..<3)
        #expect(rows.items(inRow: 2) == 3..<5)
        #expect(rows.column(ofItem: 4) == 1)
        #expect(rows.span(ofItem: 5) == 3)
        let uniform = LazyGridRows(itemCount: 7, columns: 3, spans: nil)
        #expect(uniform.count == 3 && uniform.items(inRow: 2) == 6..<7)
        let window = LazyGrid<Range<Int>, Int, EmptyView>.visibleColumns(count: 100, width: 50, spacing: 10, offset: 600,
                                                                          viewport: 240, overscan: 1)
        #expect(window == 9..<15)
    }

    @Test("A fixed-width LazyGrid builds only cells near the viewport on both axes")
    func lazyTwoAxisWindow() {
        InteractiveScene.run(width: 400, height: 300) { scene in
            var built = Set<Int>()
            scene.install(LazyGrid(0..<5_000, id: \.self, columns: 50, rowHeights: .fixed(30), overscan: 1, columnWidth: 80) { item in
                built.insert(item)
                return Text("\(item)")
            }.frame(width: 400, height: 300))
            let cells = scene.all { node in node.accessibility?.label.allSatisfy(\.isNumber) == true && node.accessibility?.label.isEmpty == false }
            #expect(!cells.isEmpty)
            #expect(cells.count < 200)
            #expect(built.contains(0))
            #expect(!built.contains(49))
        }
    }
}
