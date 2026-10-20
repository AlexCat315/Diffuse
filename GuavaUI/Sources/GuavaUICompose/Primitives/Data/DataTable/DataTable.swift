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
    public var columnVisibility: Binding<[String: Bool]>?
    /// Display order by column ID; header drags and Option/Alt+Left/Right write it.
    public var columnOrder: Binding<[String]>?
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
    var visibility: [String: Bool] = [:]
    var viewport = ScrollViewport(offset: .zero, size: .zero)
    var offset = CGPoint.zero
    var editing: DataTableCellDraft<ID>?
    var lastNavigation: AnyHashable?
    var order: [String] = []
    var columnDrag: DataTableColumnDrag?
    let focus = DataTableFocusTarget()
    let rowHeights = DataTableRowHeightCache()
}
struct DataTableColumnDrag: Equatable {
    let columnID: String
    var offset: Float
}

/// A persistent row model, fixed header, frozen leading columns and two-axis
/// cell window. Only visible rows/columns plus overscan create view nodes.
/// Row selection and cell edit drafts are transient, independent of the model.
public struct DataTable<Record: Sendable, ID: Hashable & Sendable>: View {
    public let model: DataTableModel<Record, ID>
    public private(set) var columns: [TableColumn<Record>]
    public var options = DataTableOptions<ID>()
    public var onActivate: ((Record) -> Void)?
    /// Per-record logical height (scaled with text). `nil` keeps every row at
    /// `options.layout.rowHeight`, which also remains the minimum.
    public var rowHeight: ((Record) -> Float)?
    var textScaler = TextScaler.identity
    /// Every column ID in display order, including hidden columns.
    var displayOrder: [String] = []
    /// Hierarchy keys (TreeTable) get the first chance at row navigation.
    var rowKeyHandler: ((KeyEvent, ID) -> Bool)?
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
    var orderBinding: Binding<[String]> {
        options.columnOrder ?? Binding(get: { session.order }, set: { session.order = $0 })
    }
    private var visibilityBinding: Binding<[String: Bool]> {
        options.columnVisibility ?? Binding(get: { session.visibility }, set: { session.visibility = $0 })
    }
    public var body: some View {
        SurfaceReader { surface in
            TextScalerReader { scaler in
                var table = self
                table.options.layout = options.layout.resolved(in: surface, textScaler: scaler)
                table.textScaler = scaler
                let ordered = DataTableColumnOrder.apply(orderBinding.wrappedValue, to: columns)
                table.displayOrder = ordered.map(\.id)
                if let request = options.navigation.requestID, request != session.lastNavigation,
                   let rowID = options.navigation.rowID, model.index(for: rowID) != nil,
                   let id = options.navigation.columnID, let column = columns.first(where: { $0.id == id }),
                   column.visibility != .required, visibilityBinding.wrappedValue[id] != true {
                    visibilityBinding.wrappedValue[id] = true
                }
                return TableColumns(columns: ordered, widths: options.columnWidths?.wrappedValue ?? session.widths,
                    overrides: visibilityBinding, frozenCount: options.frozenColumnCount,
                    pinnedIDs: Set(session.editing.map { [$0.columnID] } ?? []), isEnabled: options.isEnabled) { plan in
                    var presented = table; presented.columns = plan.indices.map { ordered[$0] }
                    presented.options.frozenColumnCount = plan.frozenCount
                    return presented.content(availableWidth: plan.availableWidth)
                }
            }
        }
    }
    private func content(availableWidth: Float) -> some View {
        let _ = observedRevision.wrappedValue
        if let focused = selectionBinding.wrappedValue.focusedColumnID, !columns.contains(where: { $0.id == focused }) {
            var selection = selectionBinding.wrappedValue
            selection.focusedColumnID = columns.first?.id; selectionBinding.wrappedValue = selection
        }
        if options.navigation.requestID != nil, options.navigation.requestID != session.lastNavigation,
           let id = options.navigation.rowID, let row = model.index(for: id) {
            session.lastNavigation = options.navigation.requestID
            reveal(row: row, column: columns.firstIndex { $0.id == options.navigation.columnID })
        }
        let geometry = geometry
        let metrics = rowMetrics
        let rows = metrics.visibleRange(offset: Float(session.offset.y), viewport: Float(session.viewport.size.height), overscan: 3)
        // Empty tables have no row scroller to publish a viewport. Their
        // headers still use the allocated width rather than an empty window.
        let movingWidth = model.count == 0 ? availableWidth - geometry.frozenWidth : Float(session.viewport.size.width)
        let moving = geometry.visibleColumns(offset: Float(session.offset.x), width: movingWidth)
        return DataTableInputHost(focus: session.focus, isEnabled: options.isEnabled, onKey: handleKey,
            content: Box(direction: .column, alignItems: .stretch, spacing: 0) {
                header(geometry: geometry, moving: moving).flex(0, shrink: 0)
                Divider()
                if model.count == 0 {
                    EmptyState(options.layout.emptyTitle, message: "Change your filters or add a record.", action: { EmptyView() }).flex(1)
                } else {
                    bodyViewport(rows: rows, moving: moving, geometry: geometry, metrics: metrics).flex(1, shrink: 1, basis: 0).frame(minHeight: 0)
                }
                if let message = session.editing?.error {
                    Text(message).font(.caption).foregroundColor(.error).padding(horizontal: 10, vertical: 5)
                        .accessibility { $0.role = .status }
                }
            }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0))
            .border(.border, width: 1).cornerRadius(.groupRadius).opacity(options.isEnabled ? 1 : 0.55)
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
            // Absolute, so the insertion line never takes part in the header flow.
            if let indicator = columnDropIndicator(geometry: geometry) { indicator }
        }.frame(height: options.layout.headerHeight).background(.surfaceVariant))
    }
    private func headerCells(in range: Range<Int>, geometry: DataTableColumnGeometry) -> AnyView {
        AnyView(Row(alignment: .center, spacing: 0) {
            if range.lowerBound >= geometry.frozenCount, range.lowerBound < geometry.starts.count {
                Box {}.frame(width: geometry.starts[range.lowerBound] - geometry.frozenWidth).flex(0, shrink: 0)
            }
            for index in range {
                let columnID = columns[index].id
                AnyView(DataTableHeaderDragHost(isEnabled: options.isEnabled, onChange: { offset in
                    let next = offset.map { DataTableColumnDrag(columnID: columnID, offset: $0) }
                    if session.columnDrag != next { session.columnDrag = next }
                }, onDrop: { dropColumn(at: index, offset: $0, geometry: geometry) },
                    content: headerCell(columns[index], width: geometry.widths[index])).id(columnID))
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
            .opacity(session.columnDrag?.columnID == column.id ? 0.5 : 1)
            .modifier(TableColumnIdentity(id: column.id))
    }
    private func bodyViewport(rows: Range<Int>, moving: Range<Int>, geometry: DataTableColumnGeometry,
                              metrics: DataTableRowMetrics) -> AnyView {
        let height = metrics.total
        return AnyView(Box(direction: .row, alignItems: .stretch, spacing: 0) {
            if geometry.frozenCount > 0 {
                DataTableClippedPane(onWheel: scrollWheel,
                    content: rowWindow(rows, columns: 0..<geometry.frozenCount, geometry: geometry, metrics: metrics)
                        .frame(width: geometry.frozenWidth, height: height).absolutePosition(left: 0, top: -Float(session.offset.y)))
                    .frame(width: geometry.frozenWidth, minHeight: 0).flex(0, shrink: 0).background(.surface)
            }
            ScrollView(.both, scrollbarGutter: .stable,
                scrollOffset: Binding(get: { session.offset }, set: { if session.offset != $0 { session.offset = $0 } }),
                onViewportChange: { if session.viewport != $0 { session.viewport = $0 } }) {
                rowWindow(rows, columns: moving, geometry: geometry, metrics: metrics)
                    .frame(width: max(geometry.movingWidth, Float(session.viewport.size.width)), height: height)
            }.flex(1, shrink: 1).frame(minWidth: 0, minHeight: 0)
        }.frame(minHeight: 0))
    }
    private func rowWindow(_ rows: Range<Int>, columns range: Range<Int>, geometry: DataTableColumnGeometry,
                           metrics: DataTableRowMetrics) -> AnyView {
        if range.isEmpty { return AnyView(Box {}.frame(height: metrics.total)) }
        return AnyView(Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Box {}.frame(height: metrics.top(rows.lowerBound)).flex(0, shrink: 0)
            for index in rows {
                AnyView(row(index, columns: range, geometry: geometry, height: metrics.height(index)).id(model.rowID(at: index)))
            }
            Box {}.frame(height: max(0, metrics.total - metrics.top(rows.upperBound))).flex(0, shrink: 0)
        })
    }
    private func row(_ index: Int, columns range: Range<Int>, geometry: DataTableColumnGeometry, height: Float) -> some View {
        let id = model.rowID(at: index), record = model.record(at: index), selection = selectionBinding.wrappedValue
        return DataTableRowHost(index: index, isSelected: selection.selectedIDs.contains(id), isStriped: options.layout.isStriped,
            isEnabled: options.isEnabled, isFrozenLane: range.upperBound <= geometry.frozenCount && geometry.frozenCount < geometry.widths.count,
            content: Row(alignment: .center, spacing: 0) {
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
                        .frame(width: geometry.widths[columnIndex], height: height).flex(0, shrink: 0).clipped()
                        .modifier(TableColumnIdentity(id: column.id)).id(column.id))
                }
                Spacer()
            }).frame(height: height).flex(0, shrink: 0)
    }
    var rowMetrics: DataTableRowMetrics {
        session.rowHeights.metrics(model: model, minimum: options.layout.rowHeight, scaler: textScaler, rowHeight: rowHeight)
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
        let metrics = rowMetrics
        let top = CGFloat(metrics.top(row)), bottom = top + CGFloat(metrics.height(row))
        let visibleHeight = max(CGFloat(metrics.height(row)), session.viewport.size.height)
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
        let delta = event.displacement(lineStep: 30, pageWidth: Float(session.viewport.size.width), pageHeight: Float(session.viewport.size.height))
        let maximumX = max(0, CGFloat(geometry.movingWidth) - session.viewport.size.width)
        let maximumY = max(0, CGFloat(rowMetrics.total) - session.viewport.size.height)
        session.offset.x = max(0, min(maximumX, old.x - CGFloat(delta.x)))
        session.offset.y = max(0, min(maximumY, old.y - CGFloat(delta.y)))
        return (delta.x != 0 && maximumX > 0) || (delta.y != 0 && maximumY > 0)
    }
    private func handleKey(_ event: KeyEvent) -> Bool {
        guard options.isEnabled, model.count > 0, !columns.isEmpty else { return false }
        var selection = selectionBinding.wrappedValue
        let current = selection.focusedID.flatMap(model.index(for:))
        let column = selection.focusedColumnID.flatMap { id in columns.firstIndex { $0.id == id } } ?? 0
        if column == 0, let current, let rowKeyHandler, rowKeyHandler(event, model.rowID(at: current)) { return true }
        if event.modifiers.contains(.alt), event.scancode == Scancode.arrowLeft || event.scancode == Scancode.arrowRight {
            return moveColumn(at: column, by: event.scancode == Scancode.arrowLeft ? -1 : 1)
        }
        if event.scancode == Scancode.a, !event.modifiers.isDisjoint(with: [.gui, .ctrl]), options.selectionMode == .multiple {
            selection.selectedIDs = Set((0..<model.count).map { model.rowID(at: $0) }); selectionBinding.wrappedValue = selection; return true
        }
        let row: Int, nextColumn: Int
        switch event.scancode {
        case Scancode.arrowDown: row = min(model.count - 1, (current ?? -1) + 1); nextColumn = column
        case Scancode.arrowUp: row = max(0, (current ?? model.count) - 1); nextColumn = column
        case Scancode.home: row = 0; nextColumn = column
        case Scancode.end: row = model.count - 1; nextColumn = column
        case Scancode.pageUp:
            let metrics = rowMetrics, from = current ?? 0
            row = min(max(0, from - 1), metrics.row(at: metrics.top(from) - Float(session.viewport.size.height))); nextColumn = column
        case Scancode.pageDown:
            let metrics = rowMetrics, from = current ?? 0
            row = max(min(model.count - 1, from + 1), min(model.count - 1, metrics.row(at: metrics.top(from) + Float(session.viewport.size.height)))); nextColumn = column
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
