import Foundation
import Testing
import GuavaUIRuntime
@testable import GuavaUICompose

private struct Asset: Sendable {
    let id: Int
    var name: String
    var lines: Int
}

private struct Folder: Sendable {
    let id: String
    var title: String
    var children: [Folder]?
}

@Suite("DataTable column order, variable rows and TreeTable", .serialized)
@MainActor
struct DataTableLayoutTests: GuavaUIComposeSerializedSuite {
    private struct TreeHarness: View {
        let roots: [Folder]
        let onExpand: (Set<String>) -> Void
        let onSelect: (DataTableSelection<String>) -> Void
        @State var expanded: Set<String> = []
        @State var selection = DataTableSelection<String>()
        var body: some View {
            let titles = TableColumn<Folder>("title", "Name", configure: { $0.layout.width = 260 }) { Text($0.title) }
            return TreeTable(roots, id: \.id, children: \.children, columns: [titles]) {
                $0.options.expanded = Binding(get: { expanded }, set: { expanded = $0; onExpand($0) })
                $0.options.selection = Binding(get: { selection }, set: { selection = $0; onSelect($0) })
            }.frame(width: 600, height: 400)
        }
    }

    private func columns() -> [TableColumn<Asset>] {
        ["id", "name", "lines"].map { id in
            TableColumn<Asset>(id, id.capitalized, configure: { $0.layout.width = 120 }) { asset in
                Text(id == "name" ? asset.name : "\(id == "id" ? asset.id : asset.lines)")
            }
        }
    }

    @Test("Order application keeps unknown columns in authored order and moves next to the target")
    func orderModel() throws {
        let cols = columns()
        #expect(DataTableColumnOrder.apply(["lines", "ghost", "id"], to: cols).map(\.id) == ["lines", "id", "name"])
        #expect(DataTableColumnOrder.move("id", to: "lines", in: ["id", "name", "lines"]) == ["name", "lines", "id"])
        #expect(DataTableColumnOrder.move("lines", to: "id", in: ["id", "name", "lines"]) == ["lines", "id", "name"])
        let geometry = DataTableColumnGeometry(widths: [100, 100, 100], frozenCount: 0)
        #expect(DataTableColumnOrder.target(source: 0, offset: 160, geometry: geometry) == 2)
        #expect(DataTableColumnOrder.target(source: 2, offset: -120, geometry: geometry) == 1)
    }

    @Test("Option/Alt+Arrow moves the focused column and writes the order binding")
    func keyboardReorder() throws {
        try InteractiveScene.run(width: 600, height: 300) { scene in
            var order: [String] = []
            let model = DataTableModel((0..<20).map { Asset(id: $0, name: "Asset \($0)", lines: 1) }, id: \.id)
            scene.install(DataTable(model, columns: columns()) {
                $0.options.frozenColumnCount = 0
                $0.options.columnOrder = Binding(get: { order }, set: { order = $0 })
                $0.options.navigation.requestID = 1; $0.options.navigation.rowID = 0; $0.options.navigation.columnID = "id"
            }.frame(width: 600, height: 300))
            let input = try #require(scene.first { $0.attachments["dataTable.input"] as? Bool == true })
            scene.focus.focus(input)
            scene.key(Scancode.arrowDown)
            scene.key(Scancode.arrowRight, modifiers: .alt)
            #expect(order == ["name", "id", "lines"])
        }
    }

    @Test("Dragging a header past its neighbour reorders; a short drag still sorts")
    func pointerReorder() throws {
        try InteractiveScene.run(width: 600, height: 300) { scene in
            var order: [String] = []
            let model = DataTableModel((0..<5).map { Asset(id: $0, name: "Asset \($0)", lines: 1) }, id: \.id)
            var cols = columns()
            cols[0].compare = { $0.id < $1.id ? .orderedAscending : $0.id > $1.id ? .orderedDescending : .orderedSame }
            scene.install(DataTable(model, columns: cols) {
                $0.options.frozenColumnCount = 0
                $0.options.columnOrder = Binding(get: { order }, set: { order = $0 })
            }.frame(width: 600, height: 300))
            let sort = try #require(scene.labelled("Sort by Id"))
            let start = CGPoint(x: sort.absoluteFrame.midX, y: sort.absoluteFrame.midY)
            scene.drag(from: start, to: CGPoint(x: start.x + 150, y: start.y))
            #expect(order == ["name", "id", "lines"])
            #expect(model.sort == nil)
        }
    }

    @Test("Variable row heights drive the viewport, extent and row frames")
    func variableRows() {
        InteractiveScene.run(width: 600, height: 300) { scene in
            let model = DataTableModel((0..<1_000).map { Asset(id: $0, name: "Asset \($0)", lines: $0 % 3 + 1) }, id: \.id)
            var table = DataTable(model, columns: columns()) { $0.options.frozenColumnCount = 0 }
            table.rowHeight = { Float($0.lines) * 36 }
            scene.install(table.frame(width: 600, height: 300))
            let rows = scene.all { $0.accessibility?.role == .row }
                .sorted { $0.absoluteFrame.minY < $1.absoluteFrame.minY }
            #expect(rows.count >= 3 && rows.count < 30)
            #expect(abs(Float(rows[0].frame.height) - 36) < 0.5)
            #expect(abs(Float(rows[1].frame.height) - 72) < 0.5)
            #expect(abs(Float(rows[2].frame.height) - 108) < 0.5)
            let cache = DataTableRowHeightCache()
            let metrics = cache.metrics(model: model, minimum: 36, scaler: .identity, rowHeight: { Float($0.lines) * 36 })
            #expect(metrics.total == Float((0..<1_000).reduce(0) { $0 + ($1 % 3 + 1) * 36 }))
            #expect(metrics.row(at: 36 + 72 + 1) == 2)
            #expect(metrics.top(3) == 216)
        }
    }

    @Test("TreeTable indents children, expands with the disclosure and walks the hierarchy with arrows")
    func treeTable() throws {
        try InteractiveScene.run(width: 600, height: 400) { scene in
            let roots = [
                Folder(id: "src", title: "src", children: [
                    Folder(id: "ui", title: "ui", children: [Folder(id: "button", title: "Button.swift", children: nil)]),
                    Folder(id: "main", title: "main.swift", children: nil),
                ]),
                Folder(id: "readme", title: "README.md", children: nil),
            ]
            var expanded: Set<String> = []
            var selection = DataTableSelection<String>()
            scene.install(TreeHarness(roots: roots, onExpand: { expanded = $0 }, onSelect: { selection = $0 }))
            #expect(scene.labelled("ui") == nil)
            let expand = try #require(scene.labelled("Expand"))
            scene.click(expand)
            #expect(expanded == ["src"])
            let child = try #require(scene.labelled("main.swift")), parent = try #require(scene.labelled("src"))
            #expect(child.absoluteFrame.minX > parent.absoluteFrame.minX + 10)

            let input = try #require(scene.first { $0.attachments["dataTable.input"] as? Bool == true })
            scene.focus.focus(input)
            scene.key(Scancode.arrowDown) // src
            scene.key(Scancode.arrowDown) // ui
            #expect(selection.focusedID == "ui")
            scene.key(Scancode.arrowRight)
            #expect(expanded.contains("ui"))
            scene.key(Scancode.arrowRight)
            #expect(selection.focusedID == "button")
            scene.key(Scancode.arrowLeft)
            #expect(selection.focusedID == "ui")
            scene.key(Scancode.arrowLeft)
            #expect(!expanded.contains("ui"))
        }
    }

    @Test("Flattening visits only expanded branches")
    func flatten() throws {
        let roots = [Folder(id: "a", title: "a", children: [Folder(id: "b", title: "b", children: [])]),
                     Folder(id: "c", title: "c", children: nil)]
        let flattener = TreeTableFlattener<Folder, String>(id: \.id, children: \.children)
        #expect(flattener.rows(roots, expanded: []).map(\.record.id) == ["a", "c"])
        let open = flattener.rows(roots, expanded: ["a", "b"])
        #expect(open.map(\.record.id) == ["a", "b", "c"])
        #expect(open.map(\.depth) == [0, 1, 0])
        #expect(open[1].hasChildren && open[1].isExpanded)
        #expect(!open[2].hasChildren)
    }
}
