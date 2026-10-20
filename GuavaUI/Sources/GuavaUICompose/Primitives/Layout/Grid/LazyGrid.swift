import Foundation

/// A vertically scrolling, equal-column grid that constructs only visible
/// rows plus overscan. Row heights are explicit so scrolling never measures
/// the full collection. Stable item identities preserve overlapping cells.
/// Row heights and row spacing are authored logical values and follow TextScaler once.
/// Row state that must survive leaving the viewport belongs in the model.
///
/// With `columnWidth` the grid is wider than its viewport: it scrolls on both
/// axes and also constructs only the visible columns. `columnSpan` lets an
/// item cover several columns; rows are packed in order, and an item that does
/// not fit the rest of a row starts the next one.
public struct LazyGrid<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    private let data: Data
    private let id: KeyPath<Data.Element, ID>
    private let columns: Int
    private var rowHeights: GridRowHeights
    private let columnSpacing: CGFloat
    private var rowSpacing: CGFloat
    private let overscan: Int
    private let scrollOffset: Binding<CGPoint>?
    private var columnWidth: CGFloat?
    private let columnSpan: ((Data.Element) -> Int)?
    private let content: (Data.Element) -> Content
    @State private var visibleRows: Range<Int> = 0..<1
    @State private var visibleColumns: Range<Int> = 0..<1

    public init(_ data: Data, id: KeyPath<Data.Element, ID>, columns: Int,
                rowHeights: GridRowHeights = .fixed(30),
                columnSpacing: CGFloat = 0, rowSpacing: CGFloat = 0,
                overscan: Int = 3, scrollOffset: Binding<CGPoint>? = nil,
                columnWidth: CGFloat? = nil,
                columnSpan: ((Data.Element) -> Int)? = nil,
                @ViewBuilder content: @escaping (Data.Element) -> Content) {
        precondition(columns > 0, "LazyGrid requires at least one column")
        self.data = data
        self.id = id
        self.columns = columns
        self.rowHeights = rowHeights
        self.columnSpacing = GridTrackResolver.finiteNonnegative(columnSpacing)
        self.rowSpacing = GridTrackResolver.finiteNonnegative(rowSpacing)
        self.overscan = max(0, overscan)
        self.scrollOffset = scrollOffset
        self.columnWidth = columnWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.columnSpan = columnSpan
        self.content = content
        rowHeights.validate(rowCount: LazyGridRows(data: data, columns: columns, span: columnSpan).count)
    }

    public var body: some View {
        TextScalerReader { scaler in
            var grid = self
            grid.rowHeights = rowHeights.scaled(by: CGFloat(scaler.factor))
            grid.rowSpacing = rowSpacing * CGFloat(scaler.factor)
            return grid.contentView
        }
    }

    private var contentView: some View {
        let rows = LazyGridRows(data: data, columns: columns, span: columnSpan)
        let rowCount = rows.count
        let lower = min(rowCount, visibleRows.lowerBound)
        let upper = max(lower, min(rowCount, visibleRows.upperBound))
        let total = rowHeights.totalHeight(rowCount: rowCount, spacing: rowSpacing)
        let firstOffset = lower < rowCount ? rowHeights.offset(of: lower, spacing: rowSpacing) : total
        let lastOffset = upper < rowCount ? rowHeights.offset(of: upper, spacing: rowSpacing) : total
        let contentWidth = columnWidth.map { CGFloat(columns) * $0 + columnSpacing * CGFloat(columns - 1) }
        return ScrollView(columnWidth == nil ? .vertical : .both, scrollbarGutter: .stable, scrollOffset: scrollOffset,
                          onGeometryChange: { geometry in
            let next = rowHeights.visibleRows(count: rowCount, offset: geometry.offset.y,
                                             viewportHeight: geometry.viewportSize.height,
                                             spacing: rowSpacing, overscan: overscan)
            if visibleRows != next { visibleRows = next }
            if let columnWidth {
                let columnsNext = Self.visibleColumns(count: columns, width: columnWidth, spacing: columnSpacing,
                                                      offset: geometry.offset.x, viewport: geometry.viewportSize.width,
                                                      overscan: overscan)
                if visibleColumns != columnsNext { visibleColumns = columnsNext }
            }
        }) {
            Box(direction: .column, alignItems: .stretch) {
                Box {}.frame(height: Float(firstOffset)).flex(0, shrink: 0)
                (lower..<upper).map { row(at: $0, rows: rows) }
                Box {}.frame(height: Float(max(0, total - lastOffset))).flex(0, shrink: 0)
            }
            .frame(width: contentWidth.map { .points(Float($0)) }, height: .points(Float(total)), minWidth: 0)
            .flex(0, shrink: 0)
        }
    }

    private func row(at row: Int, rows: LazyGridRows) -> AnyView {
        let height = rowHeights.height(at: row)
        let gap = row + 1 < rows.count ? rowSpacing : 0
        return AnyView(Box(direction: .column, alignItems: .stretch) {
            cells(in: row, rows: rows, height: height)
                .frame(height: Float(height))
                .flex(0, shrink: 0)
                .clipped()
        }
        .frame(height: Float(height + gap))
        .flex(0, shrink: 0)
        .id(row))
    }

    @ViewBuilder
    private func cells(in row: Int, rows: LazyGridRows, height: CGFloat) -> some View {
        let items = rows.items(inRow: row)
        if let columnWidth {
            // Two-axis window: only cells overlapping the visible columns.
            let window = visibleColumns.clamped(to: 0..<columns)
            let visible = items.filter { index in
                let start = rows.column(ofItem: index), end = start + rows.span(ofItem: index)
                return start < window.upperBound && end > window.lowerBound
            }
            Box(direction: .row, alignItems: .stretch) {
                visible.map { index in
                    let element = element(at: index)
                    let start = rows.column(ofItem: index), span = rows.span(ofItem: index)
                    let x = CGFloat(start) * (columnWidth + columnSpacing)
                    let width = CGFloat(span) * columnWidth + CGFloat(span - 1) * columnSpacing
                    return AnyView(content(element)
                        .frame(width: Float(width), height: Float(height))
                        .absolutePosition(left: Float(x), top: 0)
                        .id(element[keyPath: id]))
                }
            }
        } else if columnSpan != nil {
            Grid(columns: Array(repeating: .flexible(), count: columns), columnSpacing: columnSpacing) {
                items.map { index in
                    let element = element(at: index)
                    return AnyView(content(element)
                        .frame(height: Float(height))
                        .gridCellSpan(columns: rows.span(ofItem: index))
                        .id(element[keyPath: id]))
                }
            }
        } else {
            Grid(columns: Array(repeating: .flexible(), count: columns), columnSpacing: columnSpacing) {
                items.map { index in
                    let element = element(at: index)
                    return content(element)
                        .frame(height: Float(height))
                        .id(element[keyPath: id])
                }
            }
        }
    }

    private func element(at index: Int) -> Data.Element {
        data[data.index(data.startIndex, offsetBy: index)]
    }

    static func visibleColumns(count: Int, width: CGFloat, spacing: CGFloat, offset: CGFloat,
                               viewport: CGFloat, overscan: Int) -> Range<Int> {
        guard count > 0, width > 0 else { return 0..<0 }
        let stride = width + spacing
        let first = max(0, Int(floor(max(0, offset) / stride)) - overscan)
        let last = min(count, Int(ceil((max(0, offset) + max(0, viewport)) / stride)) + overscan)
        return first..<max(first, last)
    }
}

/// Which items each LazyGrid row holds. Uniform rows are arithmetic; spans
/// are packed once per update from small integers, never from views.
struct LazyGridRows {
    let columns: Int
    let count: Int
    private let itemCount: Int
    private let rowStarts: [Int]?
    private let itemColumns: [Int]?
    private let spans: [Int]?

    init<Data: RandomAccessCollection>(data: Data, columns: Int, span: ((Data.Element) -> Int)?) {
        self.init(itemCount: data.count, columns: columns, spans: span.map { span in data.map { span($0) } })
    }

    init(itemCount: Int, columns: Int, spans rawSpans: [Int]?) {
        self.columns = max(1, columns)
        self.itemCount = itemCount
        guard let rawSpans else {
            count = itemCount / self.columns + (itemCount % self.columns == 0 ? 0 : 1)
            rowStarts = nil; itemColumns = nil; spans = nil
            return
        }
        let columnCount = self.columns
        let spans = rawSpans.map { min(columnCount, max(1, $0)) }
        var starts: [Int] = [], positions: [Int] = []
        positions.reserveCapacity(spans.count)
        var column = columnCount
        for (index, span) in spans.enumerated() {
            if column + span > columnCount { starts.append(index); column = 0 }
            positions.append(column)
            column += span
        }
        count = starts.count
        rowStarts = starts + [spans.count]
        itemColumns = positions
        self.spans = spans
    }

    func items(inRow row: Int) -> Range<Int> {
        guard let rowStarts else {
            let start = row * columns
            return start..<min(itemCount, start + columns)
        }
        return rowStarts[row]..<rowStarts[row + 1]
    }

    func column(ofItem index: Int) -> Int { itemColumns?[index] ?? index % columns }
    func span(ofItem index: Int) -> Int { spans?[index] ?? 1 }
}
