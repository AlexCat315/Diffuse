import Foundation
import Testing
import GuavaUIAgent
import GuavaUIRuntime
import GuavaUIDevToolsProtocol
@testable import GuavaUICompose

@Suite("Adaptive table columns", .serialized)
@MainActor
struct TableColumnsTests: GuavaUIComposeSerializedSuite {
    private struct Record: Sendable { let id: Int; var name: String }
    private final class Harness: View {
        let data: Bool
        let controlled: Bool
        let model = DataTableModel((0..<100).map { Record(id: $0, name: "Record \($0)") }, id: \.id)
        @State var width: Float = 720
        @State var scale: Float = 1
        @State var input: UIEnvironment.Input = [.pointer, .keyboard]
        @State var dark = false
        @State var enabled = true
        @State var overrides: [String: Bool] = [:]
        @State var widths: [String: Float] = [:]
        @State var selection = DataTableSelection<Int>()
        @State var selected: Int? = nil
        @State var sort: TableSort? = nil
        @State var navigation = DataTableNavigation<Int>()
        init(data: Bool, controlled: Bool = true) { self.data = data; self.controlled = controlled }
        var columns: [TableColumn<Record>] {
            ["Name", "Notes", "Quantity", "Category"].enumerated().map { index, title in
                TableColumn("c\(index)", title, configure: {
                    $0.layout.width = index == 0 ? 140 : 100
                    $0.visibility = index == 0 && !data ? .required : .automatic(priority: [-100, 0, 10, 5][index])
                    $0.compare = { $0.id == $1.id ? .orderedSame : $0.id < $1.id ? .orderedAscending : .orderedDescending }
                    $0.textEditing = TableTextEditing(text: { $0.name }, update: { $0.name = $1 })
                    $0.textEditing?.validate = { $0.isEmpty ? "Name is required" : nil }
                }) { Text("\(title): \($0.name)").font(.label).debugName("column-value-\(index)-\($0.id)") }
            }
        }
        var body: some View {
            var surface = UIEnvironment(); surface.input = input; surface.viewport.width = 1280
            return LayerRoot {
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    if data {
                        DataTable(model, columns: columns) {
                            $0.options.selection = $selection
                            $0.options.columnWidths = $widths
                            $0.options.columnVisibility = controlled ? $overrides : nil
                            $0.options.navigation = navigation
                            $0.options.isEnabled = enabled
                        }.flex(1, shrink: 1, basis: 0)
                    } else {
                        Table((0..<10).map { Record(id: $0, name: "Record \($0)") }, id: \.id, columns: columns) {
                            $0.options.selection = $selected; $0.options.sort = $sort
                            $0.options.columnWidths = $widths
                            $0.options.columnVisibility = controlled ? $overrides : nil
                            $0.options.isEnabled = enabled
                        }.flex(1, shrink: 1, basis: 0)
                    }
                    Button("After table") {}.accessibilityLabel("After table").flex(0, shrink: 0)
                }.flex(1, shrink: 1, basis: 0)
            }.frame(width: width, height: 360).textScaler(.init(scale)).surfaceEnvironment(surface)
                .appearance(dark ? .dark : .light).reducedMotion()
        }
    }
    private func nodes(_ root: Node?) -> [Node] {
        var pending = root.map { [$0] } ?? [], result: [Node] = []
        while let node = pending.popLast() { result.append(node); pending.append(contentsOf: node.children.reversed()) }
        return result
    }
    private func settle(_ graph: ViewGraph, _ h: Harness) {
        for _ in 0..<10 { graph.recomposer.commitAll(); graph.computeLayout(width: h.width, height: 360) }
    }
    private func scene(data: Bool = true, controlled: Bool = true,
                       _ work: (Harness, ViewGraph, PlatformInputContext, EventDispatcher, PortalStore) throws -> Void) rethrows {
        try GlobalTestLock.locked {
            let previous = TextEnvironmentHolder.current; TextEnvironmentHolder.current = TestTextEnvironmentFactory.make()
            defer { TextEnvironmentHolder.current = previous }
            let context = PlatformInputContext(), portals = PortalStore(), scheduler = AnimatorScheduler()
            context.addScopedAmbient(PortalStoreAmbient(portals))
            try context.withCurrent { try AnimatorScheduler.$current.withValue(scheduler) {
                let h = Harness(data: data, controlled: controlled), graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
                let dispatcher = EventDispatcher(tree: graph.tree, interactions: context.interactions,
                    capture: context.pointerCapture, focusChain: context.focusChain)
                graph.install(root: h); settle(graph, h)
                defer { graph.install(root: EmptyView()); scheduler.reset() }
                try work(h, graph, context, dispatcher, portals)
            } }
        }
    }
    private func button(_ label: String, _ graph: ViewGraph) throws -> Node {
        try #require(nodes(graph.tree.root).first { $0.accessibility?.label == label && $0.isFocusable })
    }
    private func click(_ node: Node, _ input: EventDispatcher) {
        let frame = node.absoluteFrame
        let event = MouseButtonEvent(button: .left, x: Float(frame.midX), y: Float(frame.midY), clicks: 1)
        input.dispatch(.mouseButtonDown(event)); input.dispatch(.mouseButtonUp(event))
    }
    private func key(_ code: UInt32, _ input: EventDispatcher, modifiers: KeyModifiers = []) {
        input.dispatch(.keyDown(.init(scancode: code, keycode: 0, modifiers: modifiers, isRepeat: false)))
    }

    @Test("Priorities, overrides, required/frozen columns and ties resolve deterministically")
    func plans() {
        let h = Harness(data: true), columns = h.columns
        func plan(_ width: Float, overrides: [String: Bool] = [:], pinned: Set<String> = []) -> TableColumnPlan {
            .resolve(columns, widths: [:], overrides: overrides, availableWidth: width, frozenCount: 1, pinnedIDs: pinned)
        }
        #expect(plan(720).indices == [0, 1, 2, 3])
        #expect(plan(378).indices == [0, 2, 3])
        #expect(plan(200).indices == [0])
        #expect(plan(200, overrides: ["c0": false, "c1": true]).indices == [0, 1])
        #expect(plan(200, pinned: ["c3"]).indices == [0, 3])
        #expect(plan(100).frozenCount == 0 && plan(100).indices == [0])
        let allFrozen = TableColumnPlan.resolve(columns, widths: [:], overrides: [:], availableWidth: 720, frozenCount: 99, pinnedIDs: [])
        #expect(allFrozen.indices == [0, 1, 2, 3] && allFrozen.frozenCount == 4)
        let geometry = DataTableColumnGeometry(widths: [140, 100, 100, 100], frozenCount: 4)
        #expect(geometry.frozenWidth == 440 && geometry.movingWidth == 0 && geometry.visibleColumns(offset: 0, width: 100).isEmpty)
        let equal = (0..<3).map { TableColumn<Int>(String($0), String($0), configure: { $0.visibility = .automatic(); $0.layout.width = 100 }) { Text(String($0)) } }
        #expect(TableColumnPlan.resolve(equal, widths: [:], overrides: [:], availableWidth: 200,
            frozenCount: 0, pinnedIDs: []).indices == [0, 1])
        #expect(TableColumnPlan.resolve(equal, widths: [:], overrides: ["0": false, "1": false, "2": false],
            availableWidth: 0, frozenCount: 0, pinnedIDs: []).indices == [0])
    }

    @Test("Both tables adapt to their actual allocation across width, scale, input and theme", arguments: [false, true])
    func matrix(data: Bool) throws {
        try scene(data: data) { h, graph, _, _, _ in
            for width: Float in [390, 720, 1280] { for scale: Float in [1, 2] {
                for input: UIEnvironment.Input in [[.touch], [.touch, .pointer, .keyboard], [.pointer, .keyboard]] {
                    for dark in [false, true] {
                        h.width = width; h.scale = scale; h.input = input; h.dark = dark; settle(graph, h)
                        let cells = nodes(graph.tree.root).filter { $0.accessibility?.role == .cell }
                        let labels = Set(cells.compactMap { $0.accessibility?.label })
                        #expect(labels == (width == 390 ? ["Name", "Quantity", "Category"] : ["Name", "Notes", "Quantity", "Category"]))
                        let picker = try button("Column visibility", graph)
                        #expect(picker.absoluteFrame.width >= 44)
                        #expect(picker.absoluteFrame.height >= 44)
                        #expect(picker.absoluteFrame.maxX <= CGFloat(width))
                        #expect(cells.allSatisfy { $0.frame.height >= (input.contains(.touch) ? 44 : 36 * CGFloat(scale)) })
                        #expect(cells.count < 80 && !graph.recomposer.hasPending)
                    }
                }
            } }
        }
    }

    @Test("Menu choices reveal hidden columns, retain resize and selection, and restore automatic layout", arguments: [false, true])
    func picker(data: Bool) throws {
        try scene(data: data) { h, graph, context, input, portals in
            h.width = 390; h.widths["c2"] = 110; h.selection.selectedIDs = [2]; h.selected = 2; settle(graph, h)
            let picker = try button("Column visibility", graph)
            click(picker, input); settle(graph, h)
            #expect(!portals.entries.isEmpty)
            let note = try button("Notes", graph)
            #expect(note.absoluteFrame.height >= 44 && note.accessibility?.state.isSelected == false)
            let required = try #require(nodes(graph.tree.root).first { $0.accessibility?.label == "Name" && $0.accessibility?.role == .button })
            #expect(required.accessibility?.state.isEnabled == false && required.accessibility?.state.isSelected == true)
            click(note, input); settle(graph, h)
            #expect(h.overrides["c1"] == true)
            #expect(nodes(graph.tree.root).contains { $0.accessibility?.role == .cell && $0.accessibility?.label == "Notes" })
            #expect(context.focusChain.focused === picker && h.widths["c2"] == 110)
            #expect(h.selection.selectedIDs == [2] && h.selected == 2)
            click(picker, input); settle(graph, h)
            click(try button("Automatic columns", graph), input); settle(graph, h)
            #expect(h.overrides.isEmpty)
            #expect(!nodes(graph.tree.root).contains { $0.accessibility?.role == .cell && $0.accessibility?.label == "Notes" })
            h.enabled = false; settle(graph, h)
            #expect(portals.entries.isEmpty && context.pointerCapture.target == nil)
        }
    }

    @Test("A live edit stays available through automatic/manual hiding and commits; navigation reveals hidden columns")
    func editAndNavigation() throws {
        try scene { h, graph, context, input, _ in
            let host = try #require(nodes(graph.tree.root).first { $0.attachments["dataTable.input"] as? Bool == true })
            context.focusChain.focus(host)
            key(Scancode.arrowDown, input); key(Scancode.arrowRight, input); key(Scancode.f2, input); settle(graph, h)
            key(Scancode.a, input, modifiers: .gui); input.dispatch(.textInput("Draft")); settle(graph, h)
            let field = try #require(context.focusChain.focused)
            h.width = 200; h.overrides["c1"] = false; settle(graph, h)
            #expect(context.focusChain.focused === field)
            #expect(nodes(graph.tree.root).contains { $0.accessibility?.label == "Edit Notes" })
            #expect(h.model.record(for: 0)?.name == "Record 0")
            key(Scancode.return, input); settle(graph, h)
            #expect(h.model.record(for: 0)?.name == "Draft" && context.focusChain.focused === host)
            #expect(h.selection.focusedColumnID == "c0")
            h.navigation.rowID = 99; h.navigation.columnID = "c1"; h.navigation.requestID = 1; settle(graph, h)
            #expect(h.overrides["c1"] == true)
            #expect(nodes(graph.tree.root).contains { $0.accessibility?.role == .cell && $0.accessibility?.label == "Notes" })
        }
    }

    @Test("Hidden sort columns retain ordering; surviving cells retain identity and focus hands off before a column leaves")
    func sortAndFocus() throws {
        try scene(data: false) { h, graph, context, input, _ in
            h.sort = TableSort("c1", direction: .descending); h.selected = 3; settle(graph, h)
            let first = try #require(nodes(graph.tree.root).first { $0.attachments[LayoutDebugAttachmentKey.debugName] as? String == "column-value-0-9" })
            let grip = try #require(nodes(graph.tree.root).first { $0.accessibility?.label == "Resize Notes column" })
            context.focusChain.focus(grip, visible: true)
            let event = MouseButtonEvent(button: .left, x: Float(grip.absoluteFrame.midX), y: Float(grip.absoluteFrame.midY), clicks: 1)
            input.dispatch(.mouseButtonDown(event))
            #expect(context.pointerCapture.target === grip)
            context.focusChain.focus(grip, visible: true)
            h.width = 390; settle(graph, h)
            #expect(context.pointerCapture.target == nil)
            let picker = try button("Column visibility", graph)
            #expect(context.focusChain.focused === picker)
            #expect(context.focusChain.isFocusVisible)
            #expect(nodes(graph.tree.root).contains { $0 === first })
            #expect(h.sort == TableSort("c1", direction: .descending) && h.selected == 3)
            h.width = 720; settle(graph, h)
            #expect(nodes(graph.tree.root).contains { $0 === first })
        }
    }

    @Test("Unbound visibility choices belong to the mounted table and reset on unmount", arguments: [false, true])
    func localSession(data: Bool) throws {
        try scene(data: data, controlled: false) { h, graph, _, input, _ in
            h.width = 390; settle(graph, h)
            click(try button("Column visibility", graph), input); settle(graph, h)
            click(try button("Notes", graph), input); settle(graph, h)
            #expect(nodes(graph.tree.root).contains { $0.accessibility?.role == .cell && $0.accessibility?.label == "Notes" })
            h.width = 720; settle(graph, h); h.width = 390; settle(graph, h)
            #expect(nodes(graph.tree.root).contains { $0.accessibility?.role == .cell && $0.accessibility?.label == "Notes" })
            graph.install(root: EmptyView()); graph.install(root: h); settle(graph, h)
            #expect(!nodes(graph.tree.root).contains { $0.accessibility?.role == .cell && $0.accessibility?.label == "Notes" })
        }
    }

    @Test("Validated AI reads exclude automatically hidden columns and discover explicit choices")
    func aiQueries() throws {
        try scene { h, graph, _, _, _ in
            h.width = 390; settle(graph, h)
            let diagnostics = UIDiagnostics(tree: graph.tree, state: graph.stateRegistry)
            @MainActor func count() throws -> Int {
                let result = diagnostics.handleReadRequest(DevToolsEnvelope(type: "diagnostics.call", id: 1, payload: .object([
                    "name": .string("query_ui_nodes"), "arguments": .object([
                        "role": .string("cell"), "text": .string("Notes"), "visible_only": .bool(true), "input_enabled_only": .bool(true)
                    ])
                ])))
                #expect(result.type == "diagnostics.call.ok")
                let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result.payload)) as? [String: Any])
                return try #require((json["data"] as? [String: Any])?["total"] as? Int)
            }
            let hidden = try count(); #expect(hidden == 0)
            h.overrides["c1"] = true; settle(graph, h)
            let revealed = try count(); #expect(revealed > 0)
            h.enabled = false; settle(graph, h)
            let disabled = try count(); #expect(disabled == 0)
        }
    }

    @Test("Empty datasets retain allocated headers; a sole frozen lane owns the row semantics")
    func emptyAndFrozen() throws {
        try scene { h, graph, _, _, _ in
            h.width = 200; settle(graph, h)
            let rows = nodes(graph.tree.root).filter { $0.accessibility?.role == .row }
            #expect(!rows.isEmpty)
            #expect(!nodes(graph.tree.root).contains { $0.accessibility?.role == .group && $0.accessibility?.label.hasPrefix("Row ") == true })
            h.model.replaceRows([]); h.width = 720; settle(graph, h)
            for title in ["Name", "Notes", "Quantity", "Category"] { _ = try button("Sort by \(title)", graph) }
            #expect(!nodes(graph.tree.root).contains { $0.accessibility?.role == .cell })
        }
    }

    @Test("A frozen cell draft survives the whole-table scrolling fallback")
    func frozenEdit() throws {
        try scene { h, graph, context, input, _ in
            let host = try #require(nodes(graph.tree.root).first { $0.attachments["dataTable.input"] as? Bool == true })
            context.focusChain.focus(host)
            key(Scancode.arrowDown, input); key(Scancode.f2, input); settle(graph, h)
            key(Scancode.a, input, modifiers: .gui); input.dispatch(.textInput("Uncommitted")); settle(graph, h)
            h.width = 150; settle(graph, h)
            #expect(h.model.record(for: 0)?.name == "Record 0")
            #expect(context.focusChain.focused?.accessibility?.label == "Edit Name")
            key(Scancode.escape, input); settle(graph, h)
            #expect(h.model.record(for: 0)?.name == "Record 0")
            key(Scancode.f2, input); settle(graph, h)
            key(Scancode.a, input, modifiers: .gui); input.dispatch(.textInput("Committed by blur")); settle(graph, h)
            let after = try button("After table", graph)
            click(after, input); settle(graph, h)
            #expect(h.model.record(for: 0)?.name == "Committed by blur" && context.focusChain.focused === after)
        }
    }
}
