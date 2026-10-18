import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Masonry", .serialized)
struct MasonryTests {
    @Test("shortest-column placement, column spacing and item spacing drive the waterfall")
    func shortestColumn() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Masonry(minimumColumnWidth: 100, maximumColumns: 2,
                                    columnSpacing: 10, itemSpacing: 8) {
            Box {}.frame(width: 80, height: 40).debugName("m-0")
            Box {}.frame(width: 80, height: 80).debugName("m-1")
            Box {}.frame(width: 80, height: 60).debugName("m-2")
            Box {}.frame(width: 80, height: 20).debugName("m-3")
        }.frame(width: 330))
        graph.computeLayout(width: 330, height: 300)
        let cells = cells(in: graph.tree.root)
        #expect(cells["m-0"]?.frame == CGRect(x: 0, y: 0, width: 80, height: 40))
        #expect(cells["m-1"]?.frame == CGRect(x: 170, y: 0, width: 80, height: 80))
        #expect(cells["m-2"]?.frame == CGRect(x: 0, y: 48, width: 80, height: 60))
        #expect(cells["m-3"]?.frame == CGRect(x: 170, y: 88, width: 80, height: 20))
    } }

    @Test("width below the two-column budget collapses to one column")
    func oneColumn() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Masonry(minimumColumnWidth: 100, maximumColumns: 2,
                                    columnSpacing: 10, itemSpacing: 8) {
            for index in 0..<4 {
                AnyView(Box {}.frame(width: 80, height: 40).debugName("m-\(index)"))
            }
        }.frame(width: 200))
        graph.computeLayout(width: 200, height: 300)
        let narrow = cells(in: graph.tree.root)
        #expect(narrow["m-0"]?.frame == CGRect(x: 0, y: 0, width: 80, height: 40))
        #expect(narrow["m-1"]?.frame == CGRect(x: 0, y: 48, width: 80, height: 40))
        #expect(narrow["m-2"]?.frame == CGRect(x: 0, y: 96, width: 80, height: 40))
        #expect(narrow["m-3"]?.frame == CGRect(x: 0, y: 144, width: 80, height: 40))
    } }

    @Test("RTL mirrors columns while preserving shortest-column order")
    func rightToLeft() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Masonry(minimumColumnWidth: 100, maximumColumns: 2,
                                    columnSpacing: 10, itemSpacing: 8) {
            Box {}.frame(width: 80, height: 40).debugName("m-0")
            Box {}.frame(width: 80, height: 80).debugName("m-1")
        }.layoutDirection(.rtl).frame(width: 330))
        graph.computeLayout(width: 330, height: 300)
        let cells = cells(in: graph.tree.root)
        #expect(cells["m-0"]?.frame == CGRect(x: 250, y: 0, width: 80, height: 40))
        #expect(cells["m-1"]?.frame == CGRect(x: 80, y: 0, width: 80, height: 80))
    } }

    @Test("maximumColumns caps wide surfaces")
    func maximumColumns() { GlobalTestLock.locked {
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: Masonry(minimumColumnWidth: 100, maximumColumns: 2,
                                    columnSpacing: 10, itemSpacing: 8) {
            Box {}.frame(width: 80, height: 40).debugName("m-0")
            Box {}.frame(width: 80, height: 40).debugName("m-1")
            Box {}.frame(width: 80, height: 40).debugName("m-2")
        }.frame(width: 1000))
        graph.computeLayout(width: 1000, height: 300)
        let wide = cells(in: graph.tree.root)
        #expect(wide["m-0"]?.frame.minX == 0)
        #expect(wide["m-1"]?.frame.minX == 505)
        #expect(wide["m-2"]?.frame.minX == 0)
        #expect(wide["m-2"]?.frame.minY == 48)
    } }

    private func cells(in root: Node?) -> [String: Node] {
        guard let root else { return [:] }
        var result: [String: Node] = [:]
        if let name = root.attachments[LayoutDebugAttachmentKey.debugName] as? String,
           name.hasPrefix("m-") {
            result[name] = root
        }
        for child in root.children { result.merge(cells(in: child)) { first, _ in first } }
        return result
    }
}
