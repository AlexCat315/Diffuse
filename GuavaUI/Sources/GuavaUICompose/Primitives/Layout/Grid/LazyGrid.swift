import Foundation

/// A vertically scrolling, equal-column grid that constructs only visible
/// rows plus overscan. Row heights are explicit so scrolling never measures
/// the full collection. Stable item identities preserve overlapping cells.
/// Row heights and row spacing are authored logical values and follow TextScaler once.
/// Row state that must survive leaving the viewport belongs in the model.
public struct LazyGrid<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    private let data: Data
    private let id: KeyPath<Data.Element, ID>
    private let tracks: [GridColumn]
    private var rowHeights: GridRowHeights
    private let columnSpacing: CGFloat
    private var rowSpacing: CGFloat
    private let overscan: Int
    private let scrollOffset: Binding<CGPoint>?
    private let content: (Data.Element) -> Content
    @State private var visibleRows: Range<Int> = 0..<1
    private var columns: Int { tracks.count }

    public init(_ data: Data, id: KeyPath<Data.Element, ID>, columns: Int,
                rowHeights: GridRowHeights = .fixed(30),
                columnSpacing: CGFloat = 0, rowSpacing: CGFloat = 0,
                overscan: Int = 3, scrollOffset: Binding<CGPoint>? = nil,
                @ViewBuilder content: @escaping (Data.Element) -> Content) {
        precondition(columns > 0, "LazyGrid requires at least one column")
        self.data = data
        self.id = id
        self.tracks = Array(repeating: .flexible(), count: columns)
        self.rowHeights = rowHeights
        self.columnSpacing = GridTrackResolver.finiteNonnegative(columnSpacing)
        self.rowSpacing = GridTrackResolver.finiteNonnegative(rowSpacing)
        self.overscan = max(0, overscan)
        self.scrollOffset = scrollOffset
        self.content = content
        rowHeights.validate(rowCount: Self.rowCount(itemCount: data.count, columns: columns))
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
        let rowCount = Self.rowCount(itemCount: data.count, columns: columns)
        let lower = min(rowCount, visibleRows.lowerBound)
        let upper = max(lower, min(rowCount, visibleRows.upperBound))
        let total = rowHeights.totalHeight(rowCount: rowCount, spacing: rowSpacing)
        let firstOffset = lower < rowCount ? rowHeights.offset(of: lower, spacing: rowSpacing) : total
        let lastOffset = upper < rowCount ? rowHeights.offset(of: upper, spacing: rowSpacing) : total
        return ScrollView(.vertical, scrollbarGutter: .stable, scrollOffset: scrollOffset,
                          onGeometryChange: { geometry in
            let next = rowHeights.visibleRows(count: rowCount, offset: geometry.offset.y,
                                             viewportHeight: geometry.viewportSize.height,
                                             spacing: rowSpacing, overscan: overscan)
            if visibleRows != next { visibleRows = next }
        }) {
            Box(direction: .column, alignItems: .stretch) {
                Box {}.frame(height: Float(firstOffset)).flex(0, shrink: 0)
                (lower..<upper).map { row(at: $0, rowCount: rowCount) }
                Box {}.frame(height: Float(max(0, total - lastOffset))).flex(0, shrink: 0)
            }
            .frame(height: Float(total), minWidth: 0)
            .flex(0, shrink: 0)
        }
    }

    private func row(at row: Int, rowCount: Int) -> AnyView {
        let start = row * columns
        let end = min(data.count, start + columns)
        let height = rowHeights.height(at: row)
        let gap = row + 1 < rowCount ? rowSpacing : 0
        return AnyView(Box(direction: .column, alignItems: .stretch) {
            Grid(columns: tracks, columnSpacing: columnSpacing) {
                (start..<end).map { index in
                    let element = data[data.index(data.startIndex, offsetBy: index)]
                    return content(element)
                        .frame(height: Float(height))
                        .id(element[keyPath: id])
                }
            }
            .frame(height: Float(height))
            .flex(0, shrink: 0)
            .clipped()
        }
        .frame(height: Float(height + gap))
        .flex(0, shrink: 0)
        .id(row))
    }

    private static func rowCount(itemCount: Int, columns: Int) -> Int {
        itemCount / columns + (itemCount % columns == 0 ? 0 : 1)
    }
}
