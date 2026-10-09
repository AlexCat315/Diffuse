import Foundation
import GuavaUIRuntime

public enum TableSortDirection: String, Codable, Sendable { case ascending, descending }
public struct TableSort: Equatable, Codable, Sendable {
    public let columnID: String
    public let direction: TableSortDirection
    public init(_ columnID: String, direction: TableSortDirection = .ascending) { self.columnID = columnID; self.direction = direction }
}

public struct TableColumnLayout {
    public var width: Float = 160
    public var minWidth: Float = 60
    public var maxWidth: Float = 800
    public var alignment: TextAlignment = .leading
    public var isResizable = true
    public init() {}
    public func constrained(_ value: Float) -> Float {
        let minimum = minWidth.isFinite ? max(24, minWidth) : 60
        let maximum = maxWidth.isFinite ? max(minimum, maxWidth) : 800
        return min(maximum, max(minimum, value.isFinite ? value : minimum))
    }
}

public struct TableColumn<Record>: Identifiable {
    public let id: String
    public let title: String
    public var layout = TableColumnLayout()
    /// Equal comparisons retain source order in both sort directions.
    public var compare: (@Sendable (Record, Record) -> ComparisonResult)?
    public var textEditing: TableTextEditing<Record>?
    let content: (Record) -> AnyView
    public init<Content: View>(_ id: String, _ title: String, configure: (inout Self) -> Void = { _ in },
                              @ViewBuilder content: @escaping (Record) -> Content) {
        self.id = id; self.title = title; self.content = { AnyView(content($0)) }; configure(&self)
    }
}

public struct TableTextEditing<Record> {
    public let text: (Record) -> String
    public let update: (inout Record, String) -> Void
    /// A message rejects the draft and preserves the authored row.
    public var validate: ((String) -> String?)?
    public init(text: @escaping (Record) -> String, update: @escaping (inout Record, String) -> Void) {
        self.text = text; self.update = update
    }
}

public struct TableLayout {
    public var rowHeight: Float = 36
    public var headerHeight: Float = 38
    public var isStriped = true
    public var emptyTitle = "No records"
    public init() {}
    mutating func validate() {
        rowHeight = rowHeight.isFinite ? max(24, rowHeight) : 36
        headerHeight = headerHeight.isFinite ? max(24, headerHeight) : 38
    }
}
public struct TableOptions<ID: Hashable> {
    public var selection: Binding<ID?>?
    public var sort: Binding<TableSort?>?
    /// When absent, resized widths belong to this mounted table's session.
    public var columnWidths: Binding<[String: Float]>?
    public var layout = TableLayout()
    public var isEnabled = true
    public init() {}
}
private struct TableSession<ID: Hashable> {
    var selection: ID?
    var sort: TableSort?
    var widths: [String: Float] = [:]
    var viewportWidth: Float = 0
}

/// A fixed header and virtualized rows sharing one horizontal scroll coordinate system.
/// Cell content may include editors; embedded controls receive input before row selection.
public struct Table<Record, ID: Hashable>: View {
    public let records: [Record]
    public let id: KeyPath<Record, ID>
    public let columns: [TableColumn<Record>]
    public var options = TableOptions<ID>()
    public var onActivate: ((Record) -> Void)?
    @State private var session = TableSession<ID>()
    public init(_ records: [Record], id: KeyPath<Record, ID>, columns: [TableColumn<Record>],
                configure: (inout Self) -> Void = { _ in }) {
        self.records = records; self.id = id; self.columns = columns; configure(&self); options.layout.validate()
        precondition(Set(columns.map(\.id)).count == columns.count, "Table column IDs must be unique")
        precondition(Set(records.map { $0[keyPath: id] }).count == records.count, "Table row IDs must be unique")
    }
    public var body: some View {
        let rows = Self.sorted(records, columns: columns, sort: sortBinding.wrappedValue)
        let positions = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element[keyPath: id], $0.offset) })
        let width = columns.reduce(Float(0)) { $0 + columnWidth($1) }
        return ScrollView(.horizontal, scrollbarGutter: .stable, onViewportChange: { viewport in
            let width = Float(viewport.size.width)
            if width != session.viewportWidth { session.viewportWidth = width }
        }) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                header.flex(0, shrink: 0)
                Divider()
                if rows.isEmpty { EmptyState(options.layout.emptyTitle, message: "Change your filters or add a record.", action: { EmptyView() }).flex(1) }
                else {
                    List(rows, id: id, selection: selectionBinding, rowHeight: options.layout.rowHeight,
                         onActivate: onActivate) { record, selected in
                        Row(alignment: .center, spacing: 0) {
                            for column in columns {
                                AnyView(Box(direction: .row, alignItems: .center, justifyContent: column.layout.alignment == .leading ? .flexStart : column.layout.alignment == .trailing ? .flexEnd : .center) { column.content(record) }.padding(horizontal: 10, vertical: 4)
                                    .frame(width: columnWidth(column), height: options.layout.rowHeight)
                                    .flex(0, shrink: 0).clipped().accessibility { $0.role = .cell; $0.label = column.title })
                            }
                        }.modifier(TableStripeModifier(isAlternate: !selected && options.layout.isStriped && positions[record[keyPath: id]].map { $0 % 2 == 1 } == true))
                    }.listRowStyle(TableRowStyle()).flex(1, shrink: 1, basis: 0).frame(minHeight: 0)
                }
            }.frame(width: max(width + 14, session.viewportWidth), minHeight: 0).flex(1, shrink: 1)
        }.border(.border, width: 1).cornerRadius(8).allowsHitTesting(options.isEnabled).opacity(options.isEnabled ? 1 : 0.55)
            .accessibility { $0.role = .table; $0.state.isEnabled = options.isEnabled }
    }
    private var header: some View {
        Row(alignment: .center, spacing: 0) {
            for column in columns {
                AnyView(Row(alignment: .center, spacing: 0) {
                    Button(isEnabled: options.isEnabled && column.compare != nil, action: { cycleSort(column.id) }) {
                        Row(alignment: .center, spacing: 6) {
                            Text(column.title).font(.label)
                            if sortBinding.wrappedValue?.columnID == column.id {
                                Text(sortBinding.wrappedValue?.direction == .ascending ? "↑" : "↓").font(.caption)
                            }
                        }.padding(horizontal: 10)
                    }.buttonStyle(TableHeaderStyle()).flex(1, shrink: 1)
                        .accessibility {
                            $0.label = "Sort by \(column.title)"
                            let direction = sortBinding.wrappedValue?.columnID == column.id ? sortBinding.wrappedValue?.direction : nil
                            $0.state.isSelected = direction != nil
                            $0.help = direction == .ascending ? "Sorted ascending. Activate to sort descending." : direction == .descending ? "Sorted descending. Activate to restore source order." : "Activate to sort ascending."
                        }
                    if column.layout.isResizable {
                        TableResizeGrip(width: widthBinding(column), layout: column.layout, isEnabled: options.isEnabled)
                            .accessibilityLabel("Resize \(column.title) column")
                    }
                }.frame(width: columnWidth(column), height: options.layout.headerHeight).flex(0, shrink: 0))
            }
        }.background(.surfaceVariant)
    }
    private var selectionBinding: Binding<ID?> {
        options.selection ?? Binding(get: { session.selection }, set: { session.selection = $0 })
    }
    private var sortBinding: Binding<TableSort?> {
        options.sort ?? Binding(get: { session.sort }, set: { session.sort = $0 })
    }
    private func columnWidth(_ column: TableColumn<Record>) -> Float {
        column.layout.constrained((options.columnWidths?.wrappedValue ?? session.widths)[column.id] ?? column.layout.width)
    }
    private func widthBinding(_ column: TableColumn<Record>) -> Binding<Float> {
        Binding(get: { columnWidth(column) }, set: { width in
            if let binding = options.columnWidths { binding.wrappedValue[column.id] = column.layout.constrained(width) }
            else { session.widths[column.id] = column.layout.constrained(width) }
        })
    }
    private func cycleSort(_ id: String) {
        switch sortBinding.wrappedValue {
        case .some(let sort) where sort.columnID == id && sort.direction == .ascending:
            sortBinding.wrappedValue = TableSort(id, direction: .descending)
        case .some(let sort) where sort.columnID == id: sortBinding.wrappedValue = nil
        default: sortBinding.wrappedValue = TableSort(id)
        }
    }
    public static func sorted(_ records: [Record], columns: [TableColumn<Record>], sort: TableSort?) -> [Record] {
        guard let sort, let compare = columns.first(where: { $0.id == sort.columnID })?.compare else { return records }
        return records.enumerated().sorted { lhs, rhs in
            let comparison = compare(lhs.element, rhs.element)
            if comparison == .orderedSame { return lhs.offset < rhs.offset }
            return comparison == (sort.direction == .ascending ? .orderedAscending : .orderedDescending)
        }.map(\.element)
    }
}

struct TableResizeGrip: _PrimitiveView {
    let width: Binding<Float>
    let layout: TableColumnLayout
    let isEnabled: Bool
    func _makeNode() -> Node { let node = Node(); node.isFocusable = true; return node }
    func _makeLayoutNode() -> LayoutNode? { let node = LayoutNode(); node.width = 6; node.alignSelf = .stretch; return node }
    func _updateNode(_ node: Node) {
        node.isFocusable = isEnabled; node.cursor = .resizeHorizontal
        node.backgroundColor = nil
        node.foregroundColor = node.theme.colors.border
        node.updateDraw(identity: isEnabled) { list, origin in
            list.addRect(UIRect(x: Float(origin.x) + 2.5, y: Float(origin.y), width: 1, height: Float(node.frame.height)), color: (node.foregroundColor ?? node.theme.colors.border).multipliedAlpha(node.opacity))
        }
        node.accessibility = AccessibilitySemantics(.slider) { $0.value = String(width.wrappedValue); $0.state.isEnabled = isEnabled }
        node.accessibilityActions = AccessibilityActions()
        if isEnabled {
            node.accessibilityActions.setValue = { if let value = Float($0), value.isFinite { width.wrappedValue = layout.constrained(value) } }
            node.accessibilityActions.increment = { width.wrappedValue = layout.constrained(width.wrappedValue + 10) }
            node.accessibilityActions.decrement = { width.wrappedValue = layout.constrained(width.wrappedValue - 10) }
        }
        guard isEnabled, let registry = InteractionRegistryHolder.current else {
            InteractionRegistryHolder.current?.remove(node)
            if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
            return
        }
        registry.setHover(node) { node.foregroundColor = $0 == .enter ? node.theme.colors.accent : node.theme.colors.border }
        registry.setPointer(node) { event, phase, eventPhase in
            guard event.button == .left, eventPhase != .capture else { return .ignored }
            if phase == .down {
                node.attachments["table.resize"] = (event.x, width.wrappedValue)
                PointerCaptureHolder.current?.acquire(node)
            } else {
                node.attachments.removeValue(forKey: "table.resize")
                if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
            }
            return .handled
        }
        registry.setMotion(node) { event, _ in
            guard PointerCaptureHolder.current?.target === node,
                  let (start, initial) = node.attachments["table.resize"] as? (Float, Float) else { return .ignored }
            width.wrappedValue = layout.constrained(initial + event.x - start); return .handled
        }
        registry.setKey(node) { event, phase in
            guard phase == .target else { return .ignored }
            if event.scancode == Scancode.arrowLeft { width.wrappedValue = layout.constrained(width.wrappedValue - 10) }
            else if event.scancode == Scancode.arrowRight { width.wrappedValue = layout.constrained(width.wrappedValue + 10) }
            else { return .ignored }
            return .handled
        }
    }
}

private struct TableStripeModifier: ViewModifier {
    let isAlternate: Bool
    func apply(node: Node) {
        node.backgroundColor = nil
        node.updateDraw(identity: isAlternate) { list, origin in
            let rect = UIRect(x: Float(origin.x), y: Float(origin.y), width: Float(node.frame.width), height: Float(node.frame.height))
            if isAlternate { list.addRect(rect, color: node.theme.colors.surfaceVariant.multipliedAlpha(node.opacity)) }
            var parent = node.parent
            while let ancestor = parent {
                if ancestor.attachments[_ListRowHost.hoveredKey] as? Bool == true {
                    list.addRect(rect, color: node.theme.colors.stateLayerHover.multipliedAlpha(node.opacity)); break
                }
                parent = ancestor.parent
            }
        }
    }
}

struct TableHeaderStyle: ButtonStyle {
    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        Box(direction: .row, alignItems: .center, justifyContent: .flexStart) { AnyView(c.label) }
            .flex(1, shrink: 1).background(c.isHovered ? c.theme.colors.stateLayerHover : .clear)
            .foregroundColor(c.theme.colors.onSurface).border(c.isFocused ? c.theme.colors.focusRing : .clear, width: c.isFocused ? 2 : 0)
    }
}

private struct TableRowStyle: ListRowStyle {
    func makeBody(configuration c: ListRowStyleConfiguration) -> some View {
        Box(direction: .column, alignItems: .stretch) { c.content }
            .flex(1, shrink: 1).background(c.isSelected ? c.theme.colors.selection : .clear)
    }
}
