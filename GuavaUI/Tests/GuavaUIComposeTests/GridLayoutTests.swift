import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("General grid layout", .serialized)
struct GridLayoutTests {
    @Test("fixed and flexible tracks share remaining width and preserve minimums")
    func fixedAndFlexibleTracks() {
        #expect(Array(GridTrackResolver.widths(columns: [.fixed(40), .flexible(minimum: 30), .flexible(minimum: 50)],
                                         availableWidth: 260, spacing: 10)) == [40, 90, 110])
        #expect(Array(GridTrackResolver.widths(columns: [.fixed(80), .flexible(minimum: 60)],
                                         availableWidth: 100, spacing: 10)) == [80, 60])
    }

    @Test("flexible maximum redistributes unused width to another track")
    func boundedFlexibleTracks() {
        #expect(Array(GridTrackResolver.widths(columns: [.flexible(minimum: 10, maximum: 30), .flexible(minimum: 10)],
                                         availableWidth: 200, spacing: 10)) == [30, 160])
    }

    @Test("adaptive tracks account for gaps and cell maximum")
    func adaptiveTracks() {
        #expect(Array(GridTrackResolver.widths(columns: [.adaptive(minimum: 80)],
                                         availableWidth: 270, spacing: 10)) == [CGFloat(250) / 3, CGFloat(250) / 3, CGFloat(250) / 3])
        #expect(Array(GridTrackResolver.widths(columns: [.adaptive(minimum: 80, maximum: 90)],
                                         availableWidth: 300, spacing: 10)) == [90, 90, 90])
        #expect(Array(GridTrackResolver.widths(columns: [.adaptive(minimum: 80)],
                                         availableWidth: 60, spacing: 10)) == [80])
    }

    @Test("intrinsic proposals use content widths within each track's bounds")
    func intrinsicTracks() {
        #expect(Array(GridTrackResolver.widths(columns: [.fixed(40), .flexible(minimum: 20, maximum: 70), .adaptive(minimum: 30)],
                                         availableWidth: nil, spacing: 5, intrinsicWidths: [90, 100, 50])) == [40, 70, 50])
    }

    @Test("large adaptive proposals store repeated tracks without per-column allocation")
    func compactAdaptiveTracks() {
        let tracks = GridTrackResolver.widths(columns: [.adaptive(minimum: 1)],
                                               availableWidth: 1_000_000_000, spacing: 0)
        #expect(tracks.count == 1_000_000_000)
        #expect(tracks[999_999_999] == 1)
        #expect(tracks.totalWidth == 1_000_000_000)
    }

    @Test("rows use tallest child and preserve authored child dimensions")
    func gridFrames() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Grid(columns: [.fixed(60), .flexible(minimum: 20)], columnSpacing: 10, rowSpacing: 7) {
            Box {}.frame(width: 40, height: 20).debugName("cell-0")
            Box {}.frame(width: 30, height: 40).debugName("cell-1")
            Box {}.frame(width: 50, height: 10).debugName("cell-2")
        }.frame(width: 200))
        graph.computeLayout(width: 200, height: 200)
        let cells = cells(in: graph.tree.root)
        #expect(cells.count == 3)
        #expect(cells["cell-0"]?.frame == CGRect(x: 0, y: 0, width: 40, height: 20))
        #expect(cells["cell-1"]?.frame == CGRect(x: 70, y: 0, width: 30, height: 40))
        #expect(cells["cell-2"]?.frame == CGRect(x: 0, y: 47, width: 50, height: 10))
    } }

    @Test("RTL mirrors cells and leading alignment within each cell")
    func rightToLeft() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Grid(columns: [.fixed(60), .fixed(80)], columnSpacing: 10) {
            Box {}.frame(width: 40, height: 20).debugName("cell-0")
            Box {}.frame(width: 30, height: 20).debugName("cell-1")
        }.layoutDirection(.rtl).frame(width: 150))
        graph.computeLayout(width: 150, height: 100)
        let cells = cells(in: graph.tree.root)
        #expect(cells["cell-0"]?.frame.minX == 110)
        #expect(cells["cell-1"]?.frame.minX == 50)
    } }

    @Test("center alignment uses the full measured row height")
    func centeredCells() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Grid(columns: [.fixed(80), .fixed(80)], alignment: .center) {
            Box {}.frame(width: 20, height: 20).debugName("cell-0")
            Box {}.frame(width: 40, height: 60).debugName("cell-1")
        }.frame(width: 160))
        graph.computeLayout(width: 160, height: 100)
        let cells = cells(in: graph.tree.root)
        #expect(cells["cell-0"]?.frame == CGRect(x: 30, y: 20, width: 20, height: 20))
        #expect(cells["cell-1"]?.frame == CGRect(x: 100, y: 0, width: 40, height: 60))
    } }

    @Test("adaptive grid changes column count when its width changes")
    func adaptiveReflow() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Grid(columns: [.adaptive(minimum: 70)], columnSpacing: 10, rowSpacing: 5) {
            for index in 0..<5 { AnyView(Box {}.frame(height: 20).debugName("cell-\(index)")) }
        })
        graph.computeLayout(width: 230, height: 200)
        #expect(cells(in: graph.tree.root)["cell-3"]?.frame.minY == 25)
        graph.computeLayout(width: 150, height: 200)
        #expect(cells(in: graph.tree.root)["cell-2"]?.frame.minY == 25)
        #expect(cells(in: graph.tree.root)["cell-4"]?.frame.minY == 50)
    } }

    private func cells(in root: Node?) -> [String: Node] {
        guard let root else { return [:] }
        var result: [String: Node] = [:]
        if let name = root.attachments[LayoutDebugAttachmentKey.debugName] as? String, name.hasPrefix("cell-") {
            result[name] = root
        }
        for child in root.children { result.merge(cells(in: child)) { first, _ in first } }
        return result
    }
}
