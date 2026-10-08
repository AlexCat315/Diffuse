import Foundation
import GuavaUIRuntime

public struct DataTableNavigation<ID: Hashable & Sendable> {
    public var requestID: AnyHashable?
    public var rowID: ID?
    public var columnID: String?
    public init() {}
}
public struct DataTableOptions<ID: Hashable & Sendable> {
    public var selection: Binding<DataTableSelection<ID>>?
    public var selectionMode: DataTableSelectionMode = .multiple
    public var columnWidths: Binding<[String: Float]>?
    public var layout = TableLayout()
    public var frozenColumnCount = 1
    public var navigation = DataTableNavigation<ID>()
    public var isEnabled = true
    public init() {}
}
struct DataTableCellDraft<ID: Hashable & Sendable> {
    let rowID: ID
    let columnID: String
    let identity = UUID()
    let original: TextBuffer
    var buffer: TextBuffer
    var error: String?
    init(rowID: ID, columnID: String, buffer: TextBuffer) {
        self.rowID = rowID; self.columnID = columnID; original = buffer; self.buffer = buffer
    }
}
struct DataTableSession<ID: Hashable & Sendable> {
    var selection = DataTableSelection<ID>()
    var widths: [String: Float] = [:]
    var viewport = ScrollViewport(offset: .zero, size: .zero)
    var offset = CGPoint.zero
    var editing: DataTableCellDraft<ID>?
    var lastNavigation: AnyHashable?
    let focus = DataTableFocusTarget()
}

/// A persistent row model, fixed header, frozen leading columns and two-axis
/// cell window. Only visible rows/columns plus overscan create view nodes.
/// Row selection and cell edit drafts are transient, independent of the model.
public struct DataTable<Record: Sendable, ID: Hashable & Sendable>: View {
    public let model: DataTableModel<Record, ID>
    public let columns: [TableColumn<Record>]
    public var options = DataTableOptions<ID>()
    public var onActivate: ((Record) -> Void)?
    private var observedRevision: Observed<DataTableModel<Record, ID>, UInt64>
    @State var session = DataTableSession<ID>()
    public init(_ model: DataTableModel<Record, ID>, columns: [TableColumn<Record>], configure: (inout Self) -> Void = { _ in }) {
        self.model = model; self.columns = columns
        observedRevision = Observed(\.revision, on: model)
        configure(&self); options.layout.validate()
        precondition(Set(columns.map(\.id)).count == columns.count, "DataTable column IDs must be unique")
    }
    var geometry: DataTableColumnGeometry {
        let widths = options.columnWidths?.wrappedValue ?? session.widths
        return DataTableColumnGeometry(widths: columns.map { $0.layout.constrained(widths[$0.id] ?? $0.layout.width) }, frozenCount: options.frozenColumnCount)
    }
    var selectionBinding: Binding<DataTableSelection<ID>> {
        options.selection ?? Binding(get: { session.selection }, set: { session.selection = $0 })
    }
    public var body: some View {
        let _ = observedRevision.wrappedValue
        if options.navigation.requestID != nil, options.navigation.requestID != session.lastNavigation,
           let id = options.navigation.rowID, let row = model.index(for: id) {
            session.lastNavigation = options.navigation.requestID
            reveal(row: row, column: columns.firstIndex { $0.id == options.navigation.columnID })
        }
        let geometry = geometry
        let rows = VirtualStack<[Int], Int, EmptyView>.visibleRange(count: model.count, rowStride: options.layout.rowHeight,
            offset: Float(session.offset.y), height: Float(session.viewport.size.height), overscan: 3)
        let moving = geometry.visibleColumns(offset: Float(session.offset.x), width: Float(session.viewport.size.width))
        return DataTableInputHost(focus: session.focus, isEnabled: options.isEnabled, onKey: handleKey,
            content: Box(direction: .column, alignItems: .stretch, spacing: 0) {
                header(geometry: geometry, moving: moving).flex(0, shrink: 0)
                Divider()
                if model.count == 0 {
                    EmptyState(options.layout.emptyTitle, message: "Change your filters or add a record.", action: { EmptyView() }).flex(1)
                } else {
                    bodyViewport(rows: rows, moving: moving, geometry: geometry).flex(1, shrink: 1, basis: 0).frame(minHeight: 0)
                }
                if let message = session.editing?.error {
                    Text(message).font(.caption).foregroundColor(.error).padding(horizontal: 10, vertical: 5)
                        .accessibility { $0.role = .status }
                }
            }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0))
            .border(.border, width: 1).cornerRadius(6).opacity(options.isEnabled ? 1 : 0.55)
            .accessibility { $0.role = .table; $0.label = "Data table"; $0.value = "\(model.count) rows, \(columns.count) columns"; $0.state.isEnabled = options.isEnabled }
    }
    private func header(geometry: DataTableColumnGeometry, moving: Range<Int>) -> AnyView {
        AnyView(Row(alignment: .top, spacing: 0) {
            if geometry.frozenCount > 0 {
                headerCells(in: 0..<geometry.frozenCount, geometry: geometry).frame(width: geometry.frozenWidth).flex(0, shrink: 0)
            }
            DataTableClippedPane(onWheel: scrollWheel,
                content: headerCells(in: moving, geometry: geometry)
                    .frame(width: max(geometry.movingWidth, Float(session.viewport.size.width)), height: options.layout.headerHeight)
                    .absolutePosition(left: -Float(session.offset.x), top: 0))
                .flex(1, shrink: 1).frame(height: options.layout.headerHeight, minWidth: 0)
            Box {}.frame(width: 12).flex(0, shrink: 0)
        }.frame(height: options.layout.headerHeight).background(.surfaceVariant))
    }
    private func headerCells(in range: Range<Int>, geometry: DataTableColumnGeometry) -> AnyView {
        AnyView(Row(alignment: .center, spacing: 0) {
            if range.lowerBound >= geometry.frozenCount, range.lowerBound < geometry.starts.count {
                Box {}.frame(width: geometry.starts[range.lowerBound] - geometry.frozenWidth).flex(0, shrink: 0)
            }
            for index in range {
                AnyView(headerCell(columns[index], width: geometry.widths[index]).id(columns[index].id))
            }
            Spacer()
        })
    }
    private func headerCell(_ column: TableColumn<Record>, width: Float) -> some View {
        Row(alignment: .center, spacing: 0) {
            if column.compare == nil {
                Text(column.title, lineLimit: 1).font(.label).padding(horizontal: 10).flex(1, shrink: 1)
            } else {
                Button(isEnabled: options.isEnabled && column.compare != nil, action: { cycleSort(column) }) {
                    Row(alignment: .center, spacing: 5) {
                        Text(column.title, lineLimit: 1).font(.label)
                        if model.sort?.columnID == column.id {
                            Text(model.sort?.direction == .ascending ? "↑" : "↓").font(.caption)
                        }
                    }.padding(horizontal: 10)
                }.buttonStyle(TableHeaderStyle()).flex(1, shrink: 1)
                    .accessibility {
                        $0.label = "Sort by \(column.title)"
                        $0.value = model.sort?.columnID == column.id ? model.sort?.direction.rawValue ?? "" : "Source order"
                        $0.help = model.sorting.isPending ? "Sorting in background" : "Activate to cycle ascending, descending and source order"
                    }
            }
            if column.layout.isResizable {
                TableResizeGrip(width: widthBinding(column), layout: column.layout, isEnabled: options.isEnabled)
                    .accessibilityLabel("Resize \(column.title) column")
            }
        }.frame(width: width, height: options.layout.headerHeight).flex(0, shrink: 0).clipped()
    }
    private func bodyViewport(rows: Range<Int>, moving: Range<Int>, geometry: DataTableColumnGeometry) -> AnyView {
        let height = Float(model.count) * options.layout.rowHeight
        return AnyView(Box(direction: .row, alignItems: .stretch, spacing: 0) {
            if geometry.frozenCount > 0 {
                DataTableClippedPane(onWheel: scrollWheel,
                    content: rowWindow(rows, columns: 0..<geometry.frozenCount, geometry: geometry)
                        .frame(width: geometry.frozenWidth, height: height).absolutePosition(left: 0, top: -Float(session.offset.y)))
                    .frame(width: geometry.frozenWidth, minHeight: 0).flex(0, shrink: 0).background(.surface)
            }
            ScrollView(.both, scrollbarGutter: .stable,
                scrollOffset: Binding(get: { session.offset }, set: { if session.offset != $0 { session.offset = $0 } }),
                onViewportChange: { if session.viewport != $0 { session.viewport = $0 } }) {
                rowWindow(rows, columns: moving, geometry: geometry)
                    .frame(width: max(geometry.movingWidth, Float(session.viewport.size.width)), height: height)
            }.flex(1, shrink: 1).frame(minWidth: 0, minHeight: 0)
        }.frame(minHeight: 0))
    }
    private func rowWindow(_ rows: Range<Int>, columns range: Range<Int>, geometry: DataTableColumnGeometry) -> AnyView {
        AnyView(Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Box {}.frame(height: Float(rows.lowerBound) * options.layout.rowHeight).flex(0, shrink: 0)
            for index in rows {
                AnyView(row(index, columns: range, geometry: geometry).id(model.rowID(at: index)))
            }
            Box {}.frame(height: Float(model.count - rows.upperBound) * options.layout.rowHeight).flex(0, shrink: 0)
        })
    }
    private func row(_ index: Int, columns range: Range<Int>, geometry: DataTableColumnGeometry) -> some View {
        let id = model.rowID(at: index), record = model.record(at: index), selection = selectionBinding.wrappedValue
        return DataTableRowHost(index: index, isSelected: selection.selectedIDs.contains(id), isStriped: options.layout.isStriped,
            isEnabled: options.isEnabled, isFrozenLane: range.upperBound <= geometry.frozenCount, content: Row(alignment: .center, spacing: 0) {
                if range.lowerBound >= geometry.frozenCount, range.lowerBound < geometry.starts.count {
                    Box {}.frame(width: geometry.starts[range.lowerBound] - geometry.frozenWidth).flex(0, shrink: 0)
                }
                for columnIndex in range {
                    let column = columns[columnIndex]
                    AnyView(DataTableCellHost(title: column.title,
                        isActive: selection.focusedID == id && selection.focusedColumnID == column.id,
                        isEnabled: options.isEnabled, onSelect: { select(row: index, column: columnIndex, modifiers: $0) },
                        onEdit: {
                            if column.textEditing != nil { beginEditing(row: index, column: columnIndex) }
                            else { onActivate?(record) }
                        },
                        content: cell(record: record, rowID: id, column: column))
                        .frame(width: geometry.widths[columnIndex], height: options.layout.rowHeight).flex(0, shrink: 0).clipped().id(column.id))
                }
                Spacer()
            }).frame(height: options.layout.rowHeight).flex(0, shrink: 0)
    }
    private func widthBinding(_ column: TableColumn<Record>) -> Binding<Float> {
        Binding(get: { column.layout.constrained((options.columnWidths?.wrappedValue ?? session.widths)[column.id] ?? column.layout.width) }, set: { width in
            if let binding = options.columnWidths { binding.wrappedValue[column.id] = column.layout.constrained(width) }
            else { session.widths[column.id] = column.layout.constrained(width) }
        })
    }
    private func cycleSort(_ column: TableColumn<Record>) {
        guard commitEditing() else { return }
        let next: TableSort?
        if model.sort?.columnID != column.id { next = TableSort(column.id) }
        else if model.sort?.direction == .ascending { next = TableSort(column.id, direction: .descending) }
        else { next = nil }
        model.setSort(next, compare: column.compare)
    }
    func select(row: Int, column: Int, modifiers: KeyModifiers) {
        var selection = selectionBinding.wrappedValue
        selection.select(index: row, in: model, mode: options.selectionMode, modifiers: modifiers)
        selection.focusedColumnID = columns[column].id; selectionBinding.wrappedValue = selection
        session.focus.focus()
    }
    func reveal(row: Int, column: Int?) {
        let top = CGFloat(row) * CGFloat(options.layout.rowHeight), bottom = top + CGFloat(options.layout.rowHeight)
        let visibleHeight = max(CGFloat(options.layout.rowHeight), session.viewport.size.height)
        if top < session.offset.y { session.offset.y = top }
        else if bottom > session.offset.y + visibleHeight { session.offset.y = max(0, bottom - visibleHeight) }
        let geometry = geometry
        if let column, column >= geometry.frozenCount {
            let left = CGFloat(geometry.starts[column] - geometry.frozenWidth), right = left + CGFloat(geometry.widths[column])
            let visibleWidth = max(CGFloat(geometry.widths[column]), session.viewport.size.width)
            if left < session.offset.x { session.offset.x = left }
            else if right > session.offset.x + visibleWidth { session.offset.x = max(0, right - visibleWidth) }
        }
    }
    private func scrollWheel(_ event: MouseWheelEvent) -> Bool {
        let old = session.offset
        session.offset.x = max(0, min(max(0, CGFloat(geometry.movingWidth) - session.viewport.size.width), old.x - CGFloat(event.x * 30)))
        session.offset.y = max(0, min(max(0, CGFloat(Float(model.count) * options.layout.rowHeight) - session.viewport.size.height), old.y - CGFloat(event.y * 30)))
        return old != session.offset
    }
    private func handleKey(_ event: KeyEvent) -> Bool {
        guard options.isEnabled, model.count > 0, !columns.isEmpty else { return false }
        var selection = selectionBinding.wrappedValue
        let current = selection.focusedID.flatMap(model.index(for:))
        let column = selection.focusedColumnID.flatMap { id in columns.firstIndex { $0.id == id } } ?? 0
        if event.scancode == Scancode.a, !event.modifiers.isDisjoint(with: [.gui, .ctrl]), options.selectionMode == .multiple {
            selection.selectedIDs = Set((0..<model.count).map { model.rowID(at: $0) }); selectionBinding.wrappedValue = selection; return true
        }
        let row: Int, nextColumn: Int
        switch event.scancode {
        case Scancode.arrowDown: row = min(model.count - 1, (current ?? -1) + 1); nextColumn = column
        case Scancode.arrowUp: row = max(0, (current ?? model.count) - 1); nextColumn = column
        case Scancode.home: row = 0; nextColumn = column
        case Scancode.end: row = model.count - 1; nextColumn = column
        case Scancode.pageUp: row = max(0, (current ?? 0) - max(1, Int(Float(session.viewport.size.height) / options.layout.rowHeight))); nextColumn = column
        case Scancode.pageDown: row = min(model.count - 1, (current ?? 0) + max(1, Int(Float(session.viewport.size.height) / options.layout.rowHeight))); nextColumn = column
        case Scancode.arrowLeft: row = current ?? 0; nextColumn = max(0, column - 1)
        case Scancode.arrowRight: row = current ?? 0; nextColumn = min(columns.count - 1, column + 1)
        case Scancode.f2:
            guard let current else { return false }; beginEditing(row: current, column: column); return true
        case Scancode.return, Scancode.keypadEnter:
            guard let current else { return false }
            if columns[column].textEditing != nil { beginEditing(row: current, column: column) }
            else { onActivate?(model.record(at: current)) }; return true
        case Scancode.escape: selectionBinding.wrappedValue = DataTableSelection(); return true
        default: return false
        }
        selection.select(index: row, in: model, mode: options.selectionMode, modifiers: event.modifiers)
        selection.focusedColumnID = columns[nextColumn].id; selectionBinding.wrappedValue = selection
        reveal(row: row, column: nextColumn); return true
    }
}
