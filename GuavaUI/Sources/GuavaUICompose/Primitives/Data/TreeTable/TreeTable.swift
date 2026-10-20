import Foundation
import GuavaUIRuntime

/// One visible line of a `TreeTable`: the caller's record plus its place in
/// the hierarchy. Rows are rebuilt from the roots whenever expansion changes.
public struct TreeTableRow<Record: Sendable>: Sendable {
    public let record: Record
    public let depth: Int
    public let hasChildren: Bool
    public let isExpanded: Bool
}

public struct TreeTableOptions<ID: Hashable & Sendable> {
    /// Expanded branch IDs; session-local when `nil`.
    public var expanded: Binding<Set<ID>>?
    public var selection: Binding<DataTableSelection<ID>>?
    public var selectionMode: DataTableSelectionMode = .single
    public var columnWidths: Binding<[String: Float]>?
    public var columnVisibility: Binding<[String: Bool]>?
    public var columnOrder: Binding<[String]>?
    public var layout = TableLayout()
    public var isEnabled = true
    /// Indentation per depth level of the first column, before text scaling.
    public var indentation: Float = 16
    public init() {}
}

/// A DataTable whose first column carries the hierarchy: indentation and a
/// disclosure button. Columns, widths, priorities, ordering, virtualization
/// and keyboard grid navigation are DataTable's. With the first column
/// focused, Right expands (or moves to the first child) and Left collapses
/// (or moves to the parent), as in a tree. Sorting and cell editing are not
/// offered: siblings keep their authored order.
public struct TreeTable<Record: Sendable, ID: Hashable & Sendable>: View {
    private let roots: [Record]
    private let id: KeyPath<Record, ID>
    private let children: (Record) -> [Record]?
    private let columns: [TableColumn<Record>]
    public var options = TreeTableOptions<ID>()
    public var onActivate: ((Record) -> Void)?
    private let generation = UUID()
    @State private var store = TreeTableStore<Record, ID>()
    @State private var localExpanded: Set<ID> = []
    @State private var localSelection = DataTableSelection<ID>()
    @State private var navigation = DataTableNavigation<ID>()

    public init(_ roots: [Record], id: KeyPath<Record, ID>, children: @escaping (Record) -> [Record]?,
                columns: [TableColumn<Record>], configure: (inout Self) -> Void = { _ in }) {
        precondition(!columns.isEmpty, "TreeTable requires at least one column")
        self.roots = roots; self.id = id; self.children = children; self.columns = columns
        configure(&self)
    }

    private var expanded: Binding<Set<ID>> { options.expanded ?? $localExpanded }
    private var selection: Binding<DataTableSelection<ID>> { options.selection ?? $localSelection }

    public var body: some View {
        let rows = TreeTableFlattener(id: id, children: children).rows(roots, expanded: expanded.wrappedValue)
        let model = store.model(rows: rows, id: id, generation: generation)
        let mapped = mappedColumns()
        let options = options, activate = onActivate
        var table = DataTable(model, columns: mapped) { table in
            table.options.selection = selection
            table.options.selectionMode = options.selectionMode
            table.options.columnWidths = options.columnWidths
            table.options.columnVisibility = options.columnVisibility
            table.options.columnOrder = options.columnOrder
            table.options.layout = options.layout
            table.options.isEnabled = options.isEnabled
            table.options.frozenColumnCount = 1
            table.options.navigation = navigation
            if let activate { table.onActivate = { activate($0.record) } }
        }
        table.rowKeyHandler = { event, rowID in handleKey(event, rowID: rowID, model: model) }
        return table.accessibility { $0.role = .tree; $0.label = "Tree table" }
    }

    private func mappedColumns() -> [TableColumn<TreeTableRow<Record>>] {
        columns.enumerated().map { index, column in
            let content = column.content
            var mapped: TableColumn<TreeTableRow<Record>>
            if index == 0 {
                let indentation = options.indentation, rowID = id
                mapped = TableColumn(column.id, column.title) { (row: TreeTableRow<Record>) in
                    TreeTableDisclosureCell(row: row, indentation: indentation,
                                            toggle: { toggle(row.record[keyPath: rowID]) }) { content(row.record) }
                }
            } else {
                mapped = TableColumn(column.id, column.title) { (row: TreeTableRow<Record>) in content(row.record) }
            }
            mapped.layout = column.layout
            mapped.visibility = index == 0 ? .required : column.visibility
            return mapped
        }
    }

    private func toggle(_ rowID: ID) {
        if expanded.wrappedValue.contains(rowID) { expanded.wrappedValue.remove(rowID) }
        else { expanded.wrappedValue.insert(rowID) }
    }

    private func handleKey(_ event: KeyEvent, rowID: ID, model: DataTableModel<TreeTableRow<Record>, ID>) -> Bool {
        guard options.isEnabled, event.modifiers.isDisjoint(with: [.alt, .gui, .ctrl, .shift]),
              let index = model.index(for: rowID) else { return false }
        let row = model.record(at: index)
        switch event.scancode {
        case Scancode.arrowRight:
            guard row.hasChildren else { return false }
            if !row.isExpanded { expanded.wrappedValue.insert(rowID); return true }
            if index + 1 < model.count, model.record(at: index + 1).depth > row.depth { focus(model.rowID(at: index + 1)) }
            return true
        case Scancode.arrowLeft:
            if row.hasChildren && row.isExpanded { expanded.wrappedValue.remove(rowID); return true }
            guard row.depth > 0 else { return false }
            if let parent = (0..<index).reversed().first(where: { model.record(at: $0).depth < row.depth }) {
                focus(model.rowID(at: parent))
            }
            return true
        default:
            return false
        }
    }

    private func focus(_ rowID: ID) {
        var next = selection.wrappedValue
        next.selectedIDs = [rowID]; next.focusedID = rowID; next.anchorID = rowID
        next.focusedColumnID = columns.first?.id
        selection.wrappedValue = next
        var request = DataTableNavigation<ID>()
        request.requestID = AnyHashable(UUID()); request.rowID = rowID; request.columnID = columns.first?.id
        navigation = request
    }
}

/// Depth-first projection of expanded branches. Children of collapsed
/// branches are never visited, so cost follows the visible rows.
struct TreeTableFlattener<Record: Sendable, ID: Hashable> {
    let id: KeyPath<Record, ID>
    let children: (Record) -> [Record]?

    func rows(_ roots: [Record], expanded: Set<ID>) -> [TreeTableRow<Record>] {
        var result: [TreeTableRow<Record>] = []
        func visit(_ records: [Record], depth: Int) {
            for record in records {
                let kids = children(record)
                let isExpanded = kids != nil && expanded.contains(record[keyPath: id])
                result.append(TreeTableRow(record: record, depth: depth, hasChildren: kids != nil, isExpanded: isExpanded))
                if isExpanded, let kids { visit(kids, depth: depth + 1) }
            }
        }
        visit(roots, depth: 0)
        return result
    }
}

/// Rebuilds the DataTable model when the visible projection or the caller's
/// tree value changes. A fresh model is built rather than publishing a row
/// replacement from inside `body`, which would re-enter composition.
final class TreeTableStore<Record: Sendable, ID: Hashable & Sendable> {
    private var current: DataTableModel<TreeTableRow<Record>, ID>?
    private var generation: UUID?
    private var signature: [ID] = []
    private var expansion: [Bool] = []

    func model(rows: [TreeTableRow<Record>], id: KeyPath<Record, ID>, generation: UUID) -> DataTableModel<TreeTableRow<Record>, ID> {
        let ids = rows.map { $0.record[keyPath: id] }
        let states = rows.map(\.isExpanded)
        let rowID: KeyPath<TreeTableRow<Record>, ID> = (\TreeTableRow<Record>.record).appending(path: id)
        if let current, self.generation == generation, signature == ids, expansion == states { return current }
        let model = DataTableModel(rows, id: rowID)
        current = model; self.generation = generation; signature = ids; expansion = states
        return model
    }
}

private struct TreeTableDisclosureCell<Record: Sendable, Content: View>: View {
    let row: TreeTableRow<Record>
    let indentation: Float
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        TextScalerReader { scaler in
            Row(alignment: .center, spacing: 2) {
                Box {}.frame(width: scaler.scale(indentation) * Float(min(row.depth, 12))).flex(0, shrink: 0)
                if row.hasChildren {
                    Button(icon: .resource(row.isExpanded ? UIIcons.Navigation.chevronDown : UIIcons.Navigation.chevronRight),
                           size: 12, action: toggle)
                        .buttonStyle(.ghost).controlSize(.mini).flex(0, shrink: 0)
                        .compositionLocal(ActionControlAccessibility.label, row.isExpanded ? "Collapse" : "Expand")
                        .compositionLocal(ActionControlAccessibility.isExpanded, row.isExpanded)
                } else {
                    Box {}.frame(width: 20).flex(0, shrink: 0)
                }
                Box(direction: .row, alignItems: .center) { content() }.flex(1, shrink: 1).frame(minWidth: 0)
            }
        }
    }
}
