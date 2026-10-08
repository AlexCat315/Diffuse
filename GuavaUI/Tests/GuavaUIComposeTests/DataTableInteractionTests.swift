import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

private struct GridRow: Sendable {
    let id: Int
    var value: Int
}
@Suite("DataTable interaction", .serialized)
struct DataTableInteractionTests: GuavaUIComposeSerializedSuite {
    private func nodes(_ node: Node?) -> [Node] {
        guard let node else { return [] }; return [node] + node.children.flatMap { nodes($0) }
    }
    private func key(_ code: UInt32, modifiers: KeyModifiers = []) -> InputEvent {
        .keyDown(KeyEvent(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false))
    }
    private func settle(_ graph: ViewGraph) {
        for _ in 0..<5 { graph.recomposer.commitAll(); graph.computeLayout(width: 800, height: 340) }
    }
    @Test("200K by 100 only creates visible cells and keeps frozen cells aligned while scrolling")
    func largeWindow() throws { try GlobalTestLock.locked {
        let previous = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = previous }
        let context = PlatformInputContext()
        try context.withCurrent {
            let model = DataTableModel((0..<200_000).map { GridRow(id: $0, value: $0) }, id: \.id)
            var builds = 0
            let columns = (0..<100).map { column in
                TableColumn<GridRow>("c\(column)", "Column \(column)", configure: { $0.layout.width = 100 }) { row in
                    builds += 1; return Text("\(row.id):\(column)")
                }
            }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: DataTable(model, columns: columns) {
                $0.options.navigation.requestID = 1; $0.options.navigation.rowID = 0
            }.frame(width: 800, height: 340))
            settle(graph)
            let all = nodes(graph.tree.root)
            let cells = all.filter { $0.accessibility?.role == .cell }
            #expect(cells.count > 20 && cells.count < 200)
            let first = try #require(cells.first { $0.accessibility?.label == "Column 0" })
            let other = try #require(cells.first { $0.accessibility?.label == "Column 1" })
            #expect(first.absoluteFrame.width == 100 && other.absoluteFrame.minX == first.absoluteFrame.maxX)
            #expect(first.absoluteFrame.minY == other.absoluteFrame.minY)
            #expect(first.absoluteFrame.minY >= 38)
            let buildsAtRest = builds
            for _ in 0..<50 { graph.computeLayout(width: 800, height: 340) }
            #expect(builds == buildsAtRest)
            let input = try #require(all.first { $0.attachments["dataTable.input"] as? Bool == true })
            context.focusChain.focus(input)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions, capture: context.pointerCapture, focusChain: context.focusChain)
            dispatcher.dispatch(key(Scancode.end)); settle(graph)
            let rowIndexes = nodes(graph.tree.root).compactMap { $0.attachments["dataTable.rowIndex"] as? Int }
            #expect(rowIndexes.contains(199_999) && rowIndexes.min().map { $0 > 199_970 } == true)
            #expect(nodes(graph.tree.root).filter { $0.accessibility?.role == .cell }.count < 200)
            for _ in 0..<12 { dispatcher.dispatch(key(Scancode.arrowRight)) }
            settle(graph)
            let visible = nodes(graph.tree.root).filter { $0.accessibility?.role == .cell }
            let frozen = try #require(visible.first { $0.accessibility?.label == "Column 0" && $0.absoluteFrame.minY >= 38 && $0.absoluteFrame.minY < 340 })
            #expect(frozen.absoluteFrame.minX == first.absoluteFrame.minX)
            #expect(frozen.absoluteFrame.minY > 0 && frozen.absoluteFrame.minY < 340)
            #expect(!visible.contains { $0.accessibility?.label == "Column 1" })
            graph.install(root: EmptyView())
        }
    } }
    @Test("Pointer modifiers and keyboard navigation share controlled multi-selection")
    func controlledSelection() { GlobalTestLock.locked {
        let context = PlatformInputContext()
        context.withCurrent {
            let model = DataTableModel((0..<100).map { GridRow(id: $0, value: $0) }, id: \.id)
            var selected = DataTableSelection<Int>()
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: DataTable(model, columns: [TableColumn("v", "Value") { Text(String($0.value)) }]) {
                $0.options.selection = Binding(get: { selected }, set: { selected = $0 })
            }.frame(width: 800, height: 340))
            settle(graph)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions, capture: context.pointerCapture, focusChain: context.focusChain)
            let cells = nodes(graph.tree.root).filter { $0.accessibility?.role == .cell }
            func click(_ index: Int, modifiers: KeyModifiers) {
                let frame = cells[index].absoluteFrame
                let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1, modifiers: modifiers)
                dispatcher.dispatch(.mouseButtonDown(event)); dispatcher.dispatch(.mouseButtonUp(event))
            }
            click(1, modifiers: []); click(3, modifiers: .shift)
            #expect(selected.selectedIDs == [1, 2, 3])
            click(2, modifiers: .gui)
            #expect(selected.selectedIDs == [1, 3])
            dispatcher.dispatch(key(Scancode.arrowDown, modifiers: .shift))
            #expect(selected.selectedIDs == [2, 3])
            dispatcher.dispatch(key(Scancode.pageDown)); settle(graph)
            #expect((selected.focusedID ?? 0) > 3)
            dispatcher.dispatch(key(Scancode.escape))
            #expect(selected.selectedIDs.isEmpty)
            graph.install(root: EmptyView())
        }
    } }
    @Test("Editable cells validate drafts, commit once, cancel and restore table keyboard focus")
    func cellEditing() throws { try GlobalTestLock.locked {
        let previous = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
        defer { TextEnvironmentHolder.current = previous }
        let context = PlatformInputContext()
        try context.withCurrent {
            let model = DataTableModel([GridRow(id: 7, value: 42)], id: \.id)
            var column = TableColumn<GridRow>("value", "Value") { Text(String($0.value)) }
            column.textEditing = TableTextEditing(text: { String($0.value) }, update: { $0.value = Int($1)! })
            column.textEditing?.validate = { Int($0) == nil ? "Enter an integer" : nil }
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: DataTable(model, columns: [column]).frame(width: 800, height: 340))
            settle(graph)
            let input = try #require(nodes(graph.tree.root).first { $0.attachments["dataTable.input"] as? Bool == true })
            context.focusChain.focus(input)
            let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions, capture: context.pointerCapture, focusChain: context.focusChain)
            dispatcher.dispatch(key(Scancode.arrowDown)); dispatcher.dispatch(key(Scancode.f2)); settle(graph)
            dispatcher.dispatch(key(Scancode.return)); settle(graph)
            #expect(model.revision == 0)
            dispatcher.dispatch(key(Scancode.f2)); settle(graph)
            let field = try #require(nodes(graph.tree.root).first { $0.attachments[TextField.surfaceMarkerKey] != nil })
            #expect(context.focusChain.focused === field)
            dispatcher.dispatch(key(Scancode.a, modifiers: .gui)); dispatcher.dispatch(.textInput("oops")); dispatcher.dispatch(key(Scancode.return)); settle(graph)
            #expect(model.record(for: 7)?.value == 42)
            #expect(nodes(graph.tree.root).contains { $0.accessibility?.label == "Edit Value" && $0.accessibility?.state.isInvalid == true })
            dispatcher.dispatch(key(Scancode.a, modifiers: .gui)); dispatcher.dispatch(.textInput("99")); dispatcher.dispatch(key(Scancode.return)); settle(graph)
            #expect(model.record(for: 7)?.value == 99 && context.focusChain.focused === input)
            #expect(!nodes(graph.tree.root).contains { $0.attachments[TextField.surfaceMarkerKey] != nil })
            dispatcher.dispatch(key(Scancode.f2)); settle(graph)
            dispatcher.dispatch(.textInput("0")); dispatcher.dispatch(key(Scancode.escape)); settle(graph)
            #expect(model.record(for: 7)?.value == 99 && context.focusChain.focused === input)
            graph.install(root: EmptyView())
        }
    } }
}
