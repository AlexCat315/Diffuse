import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Collection text scaling", .serialized)
struct TextScaleRowTests: GuavaUIComposeSerializedSuite {
    private struct Harness<Content: View>: View {
        @State var scale: Float = 1
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        let width: Float
        let content: Content
        var body: some View {
            var surface = UIEnvironment()
            surface.viewport.width = width
            surface.input = input
            return content.surfaceEnvironment(surface).textScaler(.init(scale))
        }
    }

    private struct VariableGridHarness: View {
        @State var scale: Float = 1
        @State var offset = CGPoint.zero
        private let heights = GridRowHeights.variable([20, 30, 40, 50])
        var body: some View {
            LazyGrid(0..<7, id: \.self, columns: 2, rowHeights: heights,
                     rowSpacing: 5, overscan: 0, scrollOffset: $offset) {
                Text("Cell \($0)").debugName("variable-cell-\($0)")
            }.frame(width: 200, height: 120).textScaler(.init(scale))
        }
    }

    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
    private func named(_ name: String, in graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root!).first {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name
        })
    }
    private func settle(_ graph: ViewGraph, width: Float, height: Float) {
        for _ in 0..<5 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: height) }
    }
    private func scene(_ work: (ViewGraph, PlatformInputContext, EventDispatcher) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext()
            try context.withCurrent {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                defer { graph.install(root: EmptyView()) }
                try work(graph, context, dispatcher)
            }
        }
    }

    @Test("List, tables and fixed LazyGrid scale once and retain selection, focus and visible identities",
          arguments: [Float(390), 720, 1280], [false, true])
    func collectionGeometry(width: Float, light: Bool) throws {
        try scene { graph, context, _ in
            let records = Array(0..<2_000)
            var listSelection: Int? = 0
            let columns: [TableColumn<Int>] = [
                TableColumn("first", "First") { Text(String($0)) },
                TableColumn("second", "Second") { Text(String($0)) }
            ]
            let content = Box(direction: .column, alignItems: .stretch, spacing: 8) {
                List(records, id: \.self, selection: Binding(get: { listSelection }, set: { listSelection = $0 }),
                     rowHeight: 30, rowSpacing: 3) { value, _ in Text(String(value)) }
                    .frame(height: 180).debugName("list")
                Table(records, id: \.self, columns: columns).frame(height: 200).debugName("table")
                DataTable(DataTableModel(records, id: \.self), columns: columns)
                    .frame(height: 240).debugName("data-table")
                LazyGrid(0..<100_000, id: \.self, columns: 2, rowHeights: .fixed(30), rowSpacing: 5) {
                    Text(String($0)).debugName("fixed-cell-\($0)")
                }.frame(height: 180).debugName("grid")
            }.theme(light ? .defaultLight : .defaultDark)
            let harness = Harness(width: width, content: content)
            graph.install(root: harness)
            settle(graph, width: width, height: 900)
            let tableRow = try #require(nodes(named("table", in: graph)).first { $0.accessibility?.role == .listItem })
            let dataCell = try #require(nodes(named("data-table", in: graph)).first { $0.accessibility?.role == .cell })
            tableRow.accessibilityActions.activate?(); dataCell.accessibilityActions.activate?()
            settle(graph, width: width, height: 900)
            let focus = try #require(nodes(graph.tree.root!).first { $0.attachments["dataTable.input"] as? Bool == true })
            context.focusChain.focus(focus)
            let fixedCell = try named("fixed-cell-0", in: graph)
            let baseFontSize = try #require(fixedCell.layoutNode?.textMeasure?.key.font.size)

            for (scale, input): (Float, UIEnvironment.Input) in [
                (2, [.pointer, .keyboard]), (2, [.touch]), (1.25, [.touch, .pointer, .keyboard]),
                (1, [.touch]), (1, [.pointer, .keyboard])
            ] {
                harness.scale = scale; harness.input = input
                settle(graph, width: width, height: 900)
                for (name, role, authored, gap): (String, AccessibilityRole, Float, Float) in [
                    ("list", .listItem, 30, 3), ("table", .listItem, 36, 0), ("data-table", .cell, 36, 0)
                ] {
                    let all = nodes(try named(name, in: graph))
                    let rows = all.filter { $0.accessibility?.role == role }
                    let height = CGFloat(max(authored * scale, input.contains(.touch) ? 44 : 0))
                    #expect(!rows.isEmpty && rows.count < 40)
                    #expect(rows.allSatisfy { $0.frame.height == height }, "\(name) at \(scale): \(rows.map(\.frame.height))")
                    let positions = Array(Set(rows.map { $0.absoluteFrame.minY })).sorted()
                    for pair in zip(positions, positions.dropFirst()) {
                        #expect(abs(pair.1 - pair.0 - height - CGFloat(gap * scale)) <= 1)
                    }
                    if name != "list" {
                        let grip = try #require(all.first { $0.accessibility?.label == "Resize First column" })
                        #expect(abs(grip.frame.height - CGFloat(max(38 * scale, input.contains(.touch) ? 44 : 0))) <= 0.5)
                    }
                }
                let grid = try named("grid", in: graph)
                var cells: [Node] = []
                for node in nodes(grid) {
                    if let name = node.attachments[LayoutDebugAttachmentKey.debugName] as? String,
                       name.hasPrefix("fixed-cell-") { cells.append(node) }
                }
                #expect(!cells.isEmpty && cells.count < 40)
                #expect(cells.allSatisfy { abs($0.frame.height - CGFloat(30 * scale)) <= 0.5 })
                let positions = Array(Set(cells.map { $0.absoluteFrame.minY })).sorted()
                for pair in zip(positions, positions.dropFirst()) { #expect(abs(pair.1 - pair.0 - CGFloat(35 * scale)) <= 1) }
                #expect(try named("fixed-cell-0", in: graph) === fixedCell)
                #expect(fixedCell.layoutNode?.textMeasure?.key.font.size == baseFontSize * scale)
                #expect(nodes(try named("table", in: graph)).contains { $0 === tableRow })
                #expect(nodes(try named("data-table", in: graph)).contains { $0 === dataCell })
                #expect(tableRow.accessibility?.state.isSelected == true && dataCell.accessibility?.state.isSelected == true)
                #expect(listSelection == 0 && context.focusChain.focused === focus)
                #expect(!graph.recomposer.hasPending)
            }
        }
    }

    @Test("Variable LazyGrid scales cached prefixes and gaps, preserves partial rows and clamps on scale restoration")
    func variableGrid() throws {
        try scene { graph, _, _ in
            let harness = VariableGridHarness()
            graph.install(root: harness)
            settle(graph, width: 200, height: 120)
            let first = try named("variable-cell-0", in: graph)
            let scroll = try #require(nodes(graph.tree.root!).first { $0.clipsToBounds })
            #expect(scroll.children.first?.frame.height == 155)
            harness.scale = 2
            settle(graph, width: 200, height: 120)
            #expect(scroll.children.first?.frame.height == 310)
            #expect(try named("variable-cell-0", in: graph) === first)
            #expect(first.frame.height == 40)
            #expect(try named("variable-cell-2", in: graph).frame.height == 60)
            #expect(try named("variable-cell-2", in: graph).absoluteFrame.minY == 50)
            #expect(!nodes(graph.tree.root!).contains { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "variable-cell-4" })
            harness.offset = CGPoint(x: 0, y: 1_000)
            settle(graph, width: 200, height: 120)
            #expect(harness.offset.y == 190)
            let last = try named("variable-cell-6", in: graph)
            #expect(last.frame.height == 100 && last.absoluteFrame.maxY == 120)
            harness.scale = 1
            settle(graph, width: 200, height: 120)
            #expect(scroll.children.first?.frame.height == 155)
            #expect(harness.offset.y == 35)
            #expect(try named("variable-cell-6", in: graph) === last)
            #expect(last.frame.height == 50 && last.absoluteFrame.maxY == 120)
            #expect(!graph.recomposer.hasPending)
        }
    }

    @Test("DataTable paging, end reveal and frozen columns follow live text scale")
    func dataTableNavigation() throws {
        try scene { graph, context, dispatcher in
            let table = DataTable(DataTableModel(Array(0..<1_000), id: \.self), columns: [
                TableColumn("frozen", "Frozen") { Text(String($0)) },
                TableColumn("moving", "Moving") { Text(String($0)) }
            ])
            let harness = Harness(width: 390, content: table)
            graph.install(root: harness)
            settle(graph, width: 390, height: 310)
            let input = try #require(nodes(graph.tree.root!).first { $0.attachments["dataTable.input"] as? Bool == true })
            context.focusChain.focus(input)
            func key(_ code: UInt32) {
                dispatcher.dispatch(.keyDown(KeyEvent(scancode: code, keycode: 0, modifiers: [], isRepeat: false)))
                settle(graph, width: 390, height: 310)
            }
            for scale: Float in [2, 1] {
                harness.scale = scale
                settle(graph, width: 390, height: 310)
                key(Scancode.home); key(Scancode.pageDown)
                let height = CGFloat(36 * scale)
                #expect(table.session.selection.focusedID == Int(table.session.viewport.size.height / height))
                key(Scancode.end)
                #expect(table.session.offset.y == CGFloat(1_000) * height - table.session.viewport.size.height)
                let lastRows = nodes(graph.tree.root!).filter { $0.attachments["dataTable.rowIndex"] as? Int == 999 }
                #expect(lastRows.count == 2)
                #expect(lastRows.allSatisfy { $0.frame.height == height && $0.absoluteFrame.maxY <= 310 })
                #expect(lastRows[0].absoluteFrame.minY == lastRows[1].absoluteFrame.minY)
                #expect(nodes(graph.tree.root!).filter { $0.accessibility?.role == .cell }.count < 40)
                #expect(context.focusChain.focused === input && !graph.recomposer.hasPending)
            }
        }
    }
}
