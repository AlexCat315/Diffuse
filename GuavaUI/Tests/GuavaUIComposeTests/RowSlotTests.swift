import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

/// Row hosts own their height; content shorter than the row must sit on the
/// row's vertical center, never on its top edge.
@Suite("Row slots", .serialized)
struct RowSlotTests: GuavaUIComposeSerializedSuite {
    private struct Item: Identifiable { let id: Int }

    private func layout(_ root: some View, check: (ViewGraph) throws -> Void) throws {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make(size: 12, lineHeight: 16)
            defer { TextEnvironmentHolder.current = previous }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: root)
            for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 320, height: 240) }
            try check(graph)
            graph.install(root: EmptyView())
        }
    }

    private func expectCentered(_ name: String, in graph: ViewGraph, rowHeight: CGFloat) throws {
        let node = try #require(all(graph.tree.root!).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name })
        let content = node.absoluteFrame
        #expect(content.height < rowHeight)
        let host = try #require(sequence(first: node, next: \.parent).first { $0.absoluteFrame.height == rowHeight })
        let row = host.absoluteFrame
        #expect(abs(content.midY - row.midY) <= 0.5)
    }

    @Test("Tree and List rows center content shorter than the row")
    func collectionRows() throws {
        try layout(Tree([Item(id: 0)], id: \.id, children: { _ in [] }, hasChildren: { _ in false },
                        configure: { $0.layout.rowHeight = 28 }) { _, _, _, _ in
            Text("Tree row").debugName("tree-content")
        }.frame(height: 120)) { try expectCentered("tree-content", in: $0, rowHeight: 28) }

        try layout(List([Item(id: 0)], id: \.id, rowHeight: 34) { _, _ in
            Text("List row").debugName("list-content")
        }.frame(height: 120)) { try expectCentered("list-content", in: $0, rowHeight: 34) }
    }

    @Test("Menu rows center their content inside the minimum row height")
    func menuRows() throws {
        try layout(Menu([.item(MenuItem(id: "open", title: "Open") {})], width: 200)) { graph in
            let nodes = all(graph.tree.root!)
            let item = try #require(nodes.first { $0.accessibility?.role == .button && $0.accessibility?.label == "Open" }?.absoluteFrame)
            let title = try #require(nodes.first { $0.accessibility?.role == .staticText && $0.accessibility?.label == "Open" }?.absoluteFrame)
            #expect(item.height >= 32)
            #expect(abs(title.midY - item.midY) <= 0.5)
        }
    }

    private func all(_ node: Node) -> [Node] { [node] + node.children.flatMap(all) }
}
