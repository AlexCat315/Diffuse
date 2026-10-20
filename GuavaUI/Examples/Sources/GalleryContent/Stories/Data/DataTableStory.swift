import GuavaUI
import GuavaUIRuntime

private struct WarehouseRow: Sendable {
    let id: Int
    var name: String
    let category: String
    var quantity: Int
}
struct DataTableStory: View {
    let options: GalleryOptions
    @State private var model = DataTableModel([WarehouseRow](), id: \.id)
    @State private var selection = DataTableSelection<Int>()
    @State private var widths: [String: Float] = [:]
    @State private var visibility: [String: Bool] = [:]
    @State private var frozen = true
    @State private var navigation = DataTableNavigation<Int>()
    @State private var status = "Load a dataset to begin"
    @State private var order: [String] = []
    @State private var treeExpanded: Set<String> = ["engine"]
    private var columns: [TableColumn<WarehouseRow>] {
        var name = TableColumn<WarehouseRow>("name", "Asset", configure: {
            $0.layout.width = 200; $0.compare = { $0.name.localizedStandardCompare($1.name) }
            $0.textEditing = TableTextEditing(text: { $0.name }, update: { $0.name = $1 })
            $0.textEditing?.validate = { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Asset name is required" : nil }
        }) { Text($0.name, lineLimit: 1).font(.label) }
        name.layout.minWidth = 100
        let quantity = TableColumn<WarehouseRow>("quantity", "Quantity", configure: {
            $0.layout.width = 110; $0.layout.alignment = .trailing
            $0.visibility = .automatic(priority: 100)
            $0.compare = { $0.quantity == $1.quantity ? .orderedSame : $0.quantity < $1.quantity ? .orderedAscending : .orderedDescending }
            $0.textEditing = TableTextEditing(text: { String($0.quantity) }, update: { $0.quantity = Int($1) ?? $0.quantity })
            $0.textEditing?.validate = { Int($0).map { $0 >= 0 } == true ? nil : "Quantity must be a nonnegative integer" }
        }) { Text(String($0.quantity)).font(.label) }
        let category = TableColumn<WarehouseRow>("category", "Category", configure: {
            $0.layout.width = 140; $0.compare = { $0.category.compare($1.category) }
            $0.visibility = .automatic(priority: 50)
        }) { Badge($0.category) }
        return [name, category, quantity] + (0..<30).map { index in
            TableColumn<WarehouseRow>("metric\(index)", "Metric \(index + 1)", configure: {
                $0.layout.width = 120; $0.layout.alignment = .trailing; $0.visibility = .automatic()
            }) {
                Text(String(($0.id * (index + 3)) % 10_000)).font(.label)
            }
        }
    }
    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 24) {
        StorySection("Warehouse · up to 200,000 rows × 33 columns", "Load rows once. Narrow tables hide lower-priority columns. Use Columns to reveal them or restore Automatic columns; explicit choices scroll horizontally while Asset remains frozen. Double-click Asset or Quantity, or press F2, to edit.") {
            Box(direction: .row, alignItems: .center, wrap: .wrap, spacing: 10) {
                Button("Load 1,000 rows", isEnabled: options.isEnabled) { load(1_000) }.buttonStyle(.secondary)
                Button("Load 200,000 rows", isEnabled: options.isEnabled) { load(200_000) }.buttonStyle(.secondary)
                Button("Middle", isEnabled: options.isEnabled && model.count > 0) { navigate(to: model.count / 2) }.buttonStyle(.ghost)
                Button("Last row", isEnabled: options.isEnabled && model.count > 0) { navigate(to: model.count - 1) }.buttonStyle(.ghost)
                Row(alignment: .center, spacing: 8) {
                    Checkbox(isOn: $frozen, isEnabled: options.isEnabled).accessibilityLabel("Freeze Asset")
                    Text("Freeze Asset").font(.caption).accessibilityHidden()
                }
            }
            DataTable(model, columns: columns) {
                $0.options.selection = $selection; $0.options.columnWidths = $widths
                $0.options.columnVisibility = $visibility; $0.options.columnOrder = $order
                $0.options.frozenColumnCount = frozen ? 1 : 0; $0.options.navigation = navigation
                $0.options.isEnabled = options.isEnabled
                $0.onActivate = { status = "Opened \($0.name)" }
            }.frame(height: 360).flex(0, shrink: 0).debugName("gallery-data-table")
            DataTableStatus(model: model, selectedCount: selection.selectedIDs.count)
            Text(status).font(.caption).foregroundColor(.onSurfaceMuted)
            Text("Return commits · Escape cancels · Tab moves to the next editable cell · Arrows / Page Up / Page Down / Home / End navigate")
                .font(.caption).foregroundColor(.onSurfaceMuted)
            Text("Drag a header sideways or press Option/Alt+Left/Right on a cell to reorder columns. Order: \(order.isEmpty ? "authored" : order.prefix(4).joined(separator: ", "))")
                .font(.caption).foregroundColor(.onSurfaceMuted)
        }
        StorySection("TreeTable", "Hierarchy in the first column: the disclosure expands a branch; with the first column focused, Right expands or enters and Left collapses or returns to the parent.") {
            TreeTable(ProjectNode.sample, id: \.id, children: \.children, columns: [
                TableColumn<ProjectNode>("name", "Name", configure: { $0.layout.width = 260 }) { Text($0.name, lineLimit: 1).font(.label) },
                TableColumn<ProjectNode>("kind", "Kind", configure: { $0.layout.width = 120 }) { Badge($0.kind) },
                TableColumn<ProjectNode>("size", "Size", configure: { $0.layout.width = 100; $0.layout.alignment = .trailing }) {
                    Text($0.size, lineLimit: 1).font(.label)
                },
            ]) {
                $0.options.expanded = $treeExpanded
                $0.options.isEnabled = options.isEnabled
            }.frame(height: 280).flex(0, shrink: 0)
        }
        }
    }
    private func load(_ count: Int) {
        model.replaceRows((0..<count).map { WarehouseRow(id: $0, name: "Asset \($0 + 1)", category: ["Texture", "Material", "Mesh"][$0 % 3], quantity: ($0 * 17) % 250) })
        selection = DataTableSelection(); status = "\(count.formatted()) rows loaded"
        navigate(to: 0)
    }
    private func navigate(to index: Int) {
        navigation.rowID = index; navigation.columnID = "name"; navigation.requestID = (navigation.requestID as? Int ?? 0) + 1
    }
}
private struct DataTableStatus: View {
    let model: DataTableModel<WarehouseRow, Int>
    let selectedCount: Int
    private var revision: Observed<DataTableModel<WarehouseRow, Int>, UInt64>
    init(model: DataTableModel<WarehouseRow, Int>, selectedCount: Int) {
        self.model = model; self.selectedCount = selectedCount; revision = Observed(\.revision, on: model)
    }
    var body: some View {
        let _ = revision.wrappedValue
        return Text("\(model.count.formatted()) rows · \(selectedCount) selected · \(model.sorting.isPending ? "Sorting…" : "Ready") · \(model.sorting.completedBuilds) sort builds · \(model.sorting.cacheHits) cache hits")
            .font(.caption).foregroundColor(.onSurfaceMuted).accessibility { $0.role = .status }
    }
}

struct ProjectNode: Sendable {
    let id: String
    let name: String
    let kind: String
    let size: String
    var children: [ProjectNode]?

    static let sample: [ProjectNode] = [
        ProjectNode(id: "engine", name: "Engine", kind: "Package", size: "—", children: [
            ProjectNode(id: "render", name: "Render", kind: "Module", size: "—", children: [
                ProjectNode(id: "metal", name: "MetalBackend.swift", kind: "Source", size: "42 KB"),
                ProjectNode(id: "vulkan", name: "VulkanBackend.swift", kind: "Source", size: "51 KB"),
            ]),
            ProjectNode(id: "physics", name: "Physics", kind: "Module", size: "—", children: []),
        ]),
        ProjectNode(id: "editor", name: "Editor", kind: "Package", size: "—", children: [
            ProjectNode(id: "inspector", name: "Inspector.swift", kind: "Source", size: "18 KB"),
        ]),
        ProjectNode(id: "readme", name: "README.md", kind: "Document", size: "6 KB"),
    ]
}
