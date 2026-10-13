import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("DataTable nested scrolling", .serialized)
struct DataTableScrollTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }
        return [node] + node.children.flatMap { nodes($0) }
    }

    private func settle(_ graph: ViewGraph) {
        for _ in 0..<5 { graph.recomposer.commitAll(); graph.computeLayout(width: 600, height: 340) }
    }

    private func pane(in graph: ViewGraph, frozen: Bool) throws -> Node {
        try #require(nodes(graph.tree.root).first {
            $0.viewTag?.contains("DataTableClippedPane") == true
                && (frozen ? $0.frame.width == 100 : $0.frame.height == 38)
        })
    }

    private func wheel(_ delta: Float, over node: Node, dispatcher: EventDispatcher) {
        dispatcher.dispatch(.mouseWheel(MouseWheelEvent(x: 0, y: delta,
            mouseX: Float(node.absoluteFrame.midX), mouseY: Float(node.absoluteFrame.midY))))
    }

    private func nestedTable(rowCount: Int,
        _ work: (DataTable<Int, Int>, ViewGraph, PlatformInputContext, EventDispatcher, () -> CGFloat) throws -> Void
    ) rethrows {
        try GlobalTestLock.locked {
            let priorText = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = priorText }
            let context = PlatformInputContext()
            try context.withCurrent {
                let model = DataTableModel(Array(0..<rowCount), id: \.self)
                let table = DataTable(model, columns: [
                    TableColumn("frozen", "Frozen", configure: { $0.layout.width = 100 }) { Text(String($0)) },
                    TableColumn("moving", "Moving", configure: { $0.layout.width = 800 }) { Text(String($0)) }
                ])
                var parentOffset = CGPoint(x: 0, y: 100)
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                graph.install(root: ScrollView(.vertical,
                    scrollOffset: Binding(get: { parentOffset }, set: { parentOffset = $0 })) {
                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        Box {}.frame(height: 200).flex(0, shrink: 0)
                        table.frame(width: 500, height: 180).flex(0, shrink: 0)
                        Box {}.frame(height: 800).flex(0, shrink: 0)
                    }
                }.frame(width: 600, height: 340))
                settle(graph)
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                defer { graph.install(root: EmptyView()) }
                try work(table, graph, context, dispatcher, { parentOffset.y })
            }
        }
    }

    @Test("Frozen columns and fixed headers contain wheel input at both vertical boundaries", arguments: [false, true])
    func verticalBoundaries(frozen: Bool) throws {
        try nestedTable(rowCount: 100) { table, graph, context, dispatcher, parentY in
            #expect(table.session.viewport.size.height > 0)
            #expect(table.session.offset.y == 0 && parentY() == 100)
            wheel(1, over: try pane(in: graph, frozen: frozen), dispatcher: dispatcher)
            settle(graph)
            #expect(table.session.offset.y == 0 && parentY() == 100)

            let input = try #require(nodes(graph.tree.root).first { $0.attachments["dataTable.input"] as? Bool == true })
            context.focusChain.focus(input)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.end, keycode: 0, modifiers: [], isRepeat: false)))
            settle(graph)
            let maximumY = CGFloat(100 * 36) - table.session.viewport.size.height
            #expect(table.session.offset.y == maximumY && maximumY > 0)
            wheel(-1, over: try pane(in: graph, frozen: frozen), dispatcher: dispatcher)
            settle(graph)
            #expect(table.session.offset.y == maximumY && parentY() == 100)
        }
    }

    @Test("Horizontal overflow does not consume pure vertical input when rows fit", arguments: [false, true])
    func nonOverflowingAxisPassesToParent(frozen: Bool) throws {
        try nestedTable(rowCount: 1) { table, graph, _, dispatcher, parentY in
            #expect(table.session.viewport.size.width < 800)
            #expect(table.session.viewport.size.height > 36)
            wheel(-1, over: try pane(in: graph, frozen: frozen), dispatcher: dispatcher)
            settle(graph)
            #expect(parentY() > 100)
            #expect(table.session.offset.y == 0 && table.session.offset.x == 0)
        }
    }
}
