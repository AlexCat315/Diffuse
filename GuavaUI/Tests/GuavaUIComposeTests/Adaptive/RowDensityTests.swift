import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

@Suite("Adaptive collection and menu row density", .serialized)
@MainActor
struct RowDensityTests: GuavaUIComposeSerializedSuite {
    private struct Harness<Content: View>: View {
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        let width: Float
        let content: Content
        var body: some View {
            var surface = UIEnvironment()
            surface.viewport.width = width
            surface.input = input
            return content.surfaceEnvironment(surface)
        }
    }

    private func nodes(_ root: Node) -> [Node] { [root] + root.children.flatMap(nodes) }
    private func named(_ name: String, in graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root!).first {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == name
        })
    }
    private func settle(_ graph: ViewGraph, width: Float, height: Float = 820) {
        for _ in 0..<5 { graph.recomposer.commitAll(); graph.computeLayout(width: width, height: height) }
    }
    private func scene(_ work: (ViewGraph, PlatformInputContext, EventDispatcher, AnimatorScheduler) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current
            TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), portals = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                defer { graph.install(root: EmptyView()); scheduler.tick(deltaTime: 1); graph.recomposer.commitAll() }
                try work(graph, context, dispatcher, scheduler)
            } }
        }
    }

    @Test("Rows, cells, disclosure buttons and embedded controls share density and retain identity",
          arguments: [Float(390), 720, 1280], [Float(36), 56])
    func collectionRows(width: Float, authoredHeight: Float) throws {
        try scene { graph, _, _, _ in
            let records = Array(0..<1_000)
            var treeSelection: Int?
            let columns: [TableColumn<Int>] = [
                TableColumn("action", "Action") { _ in Button("Open") {} },
                TableColumn("value", "Value") { Text(String($0)) }
            ]
            let content = Box(direction: .column, alignItems: .stretch, spacing: 10) {
                Tree(records, id: \.self, children: { $0 == 0 ? [1_000] : [] }, configure: {
                    $0.layout.rowHeight = authoredHeight
                    $0.selection.primary = Binding(get: { treeSelection }, set: { treeSelection = $0 })
                }) { value, _, _, _ in Text(String(value)) }
                    .frame(height: 180).debugName("tree")
                Table(records, id: \.self, columns: columns) { $0.options.layout.rowHeight = authoredHeight }
                    .frame(height: 240).debugName("table")
                DataTable(DataTableModel(records, id: \.self), columns: columns) {
                    $0.options.layout.rowHeight = authoredHeight
                }.frame(height: 240).debugName("data-table")
            }
            let harness = Harness(width: width, content: content)
            graph.install(root: harness)
            settle(graph, width: width)
            let originalTreeRow = try #require(nodes(named("tree", in: graph)).first { $0.accessibility?.role == .treeItem })
            let originalTableRow = try #require(nodes(named("table", in: graph)).first { $0.accessibility?.role == .listItem })
            let originalCell = try #require(nodes(named("data-table", in: graph)).first { $0.accessibility?.role == .cell })
            originalTreeRow.accessibilityActions.activate?()
            originalTableRow.accessibilityActions.activate?()
            originalCell.accessibilityActions.activate?()

            for input: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
                harness.input = input
                settle(graph, width: width)
                let expected = CGFloat(input.contains(.touch) ? max(authoredHeight, 44) : authoredHeight)
                for (name, role): (String, AccessibilityRole) in [("tree", .treeItem), ("table", .listItem), ("data-table", .cell)] {
                    let all = nodes(try named(name, in: graph))
                    let rows = all.filter { $0.accessibility?.role == role }
                    #expect(!rows.isEmpty && rows.count < 40, "\(name) materialized \(rows.count) rows/cells")
                    #expect(rows.allSatisfy { $0.frame.height == expected })
                    let positions = Array(Set(rows.map { $0.absoluteFrame.minY })).sorted()
                    for pair in zip(positions, positions.dropFirst()) { #expect(pair.1 - pair.0 == expected) }
                    if input.contains(.touch) {
                        for button in all.filter({ $0.attachments[ButtonHost.markerKey] as? Bool == true }) {
                            #expect(button.frame.width >= 44 && button.frame.height >= 44)
                            var ancestor = button.parent
                            while let node = ancestor {
                                if node.accessibility?.role == .cell {
                                    #expect(button.absoluteFrame.minY >= node.absoluteFrame.minY)
                                    #expect(button.absoluteFrame.maxY <= node.absoluteFrame.maxY)
                                    break
                                }
                                ancestor = node.parent
                            }
                        }
                    }
                }
                #expect(nodes(try named("tree", in: graph)).contains { $0 === originalTreeRow })
                #expect(nodes(try named("table", in: graph)).contains { $0 === originalTableRow })
                #expect(nodes(try named("data-table", in: graph)).contains { $0 === originalCell })
                #expect(originalTreeRow.accessibility?.state.isSelected == true)
                #expect(originalTableRow.accessibility?.state.isSelected == true)
                #expect(originalCell.accessibility?.state.isSelected == true)
                #expect(!graph.recomposer.hasPending)
            }
        }
    }

    @Test("Touch DataTable paging, end reveal, frozen panes and editing use the same row height")
    func dataTableNavigation() throws {
        try scene { graph, context, dispatcher, _ in
            let model = DataTableModel(Array(0..<1_000), id: \.self)
            var column = TableColumn<Int>("value", "Value") { Text(String($0)) }
            column.textEditing = TableTextEditing(text: { String($0) }, update: { $0 = Int($1) ?? $0 })
            let table = DataTable(model, columns: [
                TableColumn("frozen", "Frozen") { Text(String($0)) }, column
            ])
            let harness = Harness(width: 390, content: table.frame(height: 310))
            harness.input = [.touch, .keyboard]
            graph.install(root: harness)
            settle(graph, width: 390, height: 310)
            let input = try #require(nodes(graph.tree.root!).first { $0.attachments["dataTable.input"] as? Bool == true })
            context.focusChain.focus(input)
            @MainActor func key(_ code: UInt32) {
                dispatcher.dispatch(.keyDown(KeyEvent(scancode: code, keycode: 0, modifiers: [], isRepeat: false)))
                settle(graph, width: 390, height: 310)
            }
            key(Scancode.arrowDown)
            key(Scancode.pageDown)
            #expect(table.session.selection.focusedID == Int(table.session.viewport.size.height / 44))
            key(Scancode.end)
            #expect(table.session.offset.y == 44_000 - table.session.viewport.size.height)
            let lastRows = nodes(graph.tree.root!).filter { $0.attachments["dataTable.rowIndex"] as? Int == 999 }
            #expect(lastRows.count == 2)
            #expect(lastRows[0].absoluteFrame.minY == lastRows[1].absoluteFrame.minY)
            #expect(lastRows.allSatisfy { $0.frame.height == 44 && $0.absoluteFrame.maxY <= 310 })
            #expect(nodes(graph.tree.root!).filter { $0.accessibility?.role == .cell }.count < 40)
            key(Scancode.arrowRight)
            key(Scancode.f2)
            let field = try #require(nodes(graph.tree.root!).first { $0.accessibility?.role == .textField })
            #expect(field.frame.height == 44)
            let cell = try #require(nodes(graph.tree.root!).first {
                $0.accessibility?.role == .cell && nodes($0).contains { $0 === field }
            })
            #expect(field.absoluteFrame.minY >= cell.absoluteFrame.minY)
            #expect(field.absoluteFrame.maxY <= cell.absoluteFrame.maxY)
            key(Scancode.escape)
            #expect(table.session.editing == nil && context.focusChain.focused === input)
        }
    }

    @Test("Touch floors preserve larger scaled tree and menu content in both themes",
          arguments: [Float(1), 2], [false, true])
    func scaledRows(scale: Float, light: Bool) throws {
        try scene { graph, _, _, _ in
            let content = Box(direction: .column, alignItems: .stretch, spacing: 10) {
                Tree(Array(0..<20), id: \.self, children: { _ in [] }) { value, _, _, _ in
                    Text(String(value))
                }.frame(height: 180).debugName("scaled-tree")
                Menu([.item(MenuItem(id: "scaled", title: "Command") {})], width: 320, maxVisibleRows: 2)
            }.theme(light ? .defaultLight : .defaultDark).textScaler(.init(scale))
            let harness = Harness(width: 390, content: content)
            harness.input = [.touch]
            graph.install(root: harness)
            settle(graph, width: 390)
            let treeRows = nodes(try named("scaled-tree", in: graph)).filter { $0.accessibility?.role == .treeItem }
            #expect(!treeRows.isEmpty && treeRows.allSatisfy { $0.frame.height == CGFloat(max(30 * scale, 44)) })
            let row = try #require(menuRow(AnyHashable("scaled"), in: graph.tree.root!))
            #expect(row.frame.height >= 44)
            if scale == 2 { #expect(row.frame.height > 44) }
            harness.input = [.pointer, .keyboard]
            settle(graph, width: 390)
            #expect(treeRows.allSatisfy { $0.frame.height == CGFloat(30 * scale) })
            #expect(row.frame.height >= 32)
            if scale == 1 { #expect(row.frame.height == 32) }
        }
    }

    @Test("Menu portals inherit touch density, grow their viewport and restore retained rows on pointer input")
    func menuRows() throws {
        try scene { graph, context, dispatcher, scheduler in
            let entries: [MenuEntry] = [
                .submenu(MenuSubmenu(id: "branch", title: "Tools", entries: [
                    .item(MenuItem(id: "leaf", title: "Build") {})
                ])),
                .item(MenuItem(id: "disabled", title: "Unavailable", isEnabled: false) {}),
                .item(MenuItem(id: "last", title: "Last") {})
            ]
            let harness = Harness(width: 390, content:
                Popover(isPresented: .constant(true), width: 220, surface: .content, overflow: .flip) { Text("Menu") } content: {
                    Menu(entries, width: 220, maxVisibleRows: 2)
                })
            harness.input = [.touch, .keyboard]
            // The PortalHost has the default pointer environment; only the trigger overrides it.
            graph.install(root: LayerRoot { harness })
            settle(graph, width: 390)
            scheduler.tick(deltaTime: 1); settle(graph, width: 390)
            let branch = try #require(menuRow(AnyHashable("branch"), in: graph.tree.root!))
            let disabled = try #require(menuRow(AnyHashable("disabled"), in: graph.tree.root!))
            #expect(branch.frame.height == 44 && disabled.frame.height == 44)
            let scroll = try #require(nodes(graph.tree.root!).first { $0.attachments[MenuScrollMarker.key] as? Bool == true })
            #expect(scroll.frame.height >= 88)
            context.focusChain.focus(branch)
            let press = MouseButtonEvent(button: .left, x: Float(branch.absoluteFrame.midX),
                y: Float(branch.absoluteFrame.maxY - 1), clicks: 1)
            dispatcher.dispatch(.mouseButtonDown(press)); dispatcher.dispatch(.mouseButtonUp(press))
            settle(graph, width: 390)
            let leaf = try #require(menuRow(AnyHashable("leaf"), in: graph.tree.root!))
            #expect(leaf.frame.height == 44 && leaf.accessibility?.label == "Build")
            harness.input = [.pointer, .keyboard]
            settle(graph, width: 390)
            #expect(menuRow(AnyHashable("branch"), in: graph.tree.root!) === branch)
            #expect(menuRow(AnyHashable("leaf"), in: graph.tree.root!) === leaf)
            #expect(branch.frame.height == 32 && disabled.frame.height == 32 && leaf.frame.height == 32)
            #expect(branch.accessibility?.state.isExpanded == true)
            dispatcher.dispatch(.keyDown(KeyEvent(scancode: Scancode.arrowLeft, keycode: 0, modifiers: [], isRepeat: false)))
            settle(graph, width: 390)
            #expect(menuRow(AnyHashable("leaf"), in: graph.tree.root!) == nil)
            #expect(!graph.recomposer.hasPending)
        }
    }
}
