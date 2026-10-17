import Foundation

/// A general row-major grid built on the public measurement and placement
/// contract. Row heights come from the tallest measured child in each row.
/// Cells do not span rows or columns.
public struct GridLayout: Layout {
    public var columns: [GridColumn]
    public var columnSpacing: CGFloat = 0
    public var rowSpacing: CGFloat = 0
    public var alignment: Alignment = .topLeading
    public var columnVisibility: [String: Bool] = [:]

    public init(columns: [GridColumn], columnSpacing: CGFloat = 0,
                rowSpacing: CGFloat = 0, alignment: Alignment = .topLeading, columnVisibility: [String: Bool] = [:]) {
        self.columns = columns
        self.columnSpacing = columnSpacing
        self.rowSpacing = rowSpacing
        self.alignment = alignment
        self.columnVisibility = columnVisibility
        _ = GridNamedColumns.tracks(columns)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        arrangement(proposal: proposal, subviews: subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        let arrangement = arrangement(proposal: .init(width: bounds.width), subviews: subviews)
        guard !arrangement.widths.isEmpty else {
            for child in subviews { child.place(at: .zero, proposal: .zero, isVisible: false) }
            return
        }
        let gap = GridTrackResolver.finiteNonnegative(columnSpacing)
        let rowGap = GridTrackResolver.finiteNonnegative(rowSpacing)
        let rtl = subviews.first?.layoutDirection == .rtl
        let components = alignmentComponents
        var y = bounds.minY
        var row = 0
        var x: CGFloat = 0
        for index in subviews.indices {
            let column = index % arrangement.sourceColumnCount
            if column == 0 { x = 0 }
            if let presented = arrangement.presentedColumn(column) {
                let cellWidth = arrangement.widths[presented]
                let itemSize = arrangement.itemSizes[index]
                let horizontal = horizontalOffset(components.horizontal, available: cellWidth - itemSize.width, rtl: rtl)
                let vertical = verticalOffset(components.vertical, available: arrangement.heights[row] - itemSize.height)
                let cellX = rtl ? bounds.maxX - x - cellWidth : bounds.minX + x
                subviews[index].place(at: CGPoint(x: cellX + horizontal, y: y + vertical),
                                      proposal: .init(width: cellWidth, height: itemSize.height))
                x += cellWidth + gap
            } else { subviews[index].place(at: .zero, proposal: .zero, isVisible: false) }
            if column + 1 == arrangement.sourceColumnCount || index + 1 == subviews.count {
                if arrangement.activeRows[row] { y += arrangement.heights[row] + rowGap }
                row += 1
            }
        }
    }

    private func arrangement(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> GridArrangement {
        guard !columns.isEmpty, !subviews.isEmpty else { return .empty }
        let gap = GridTrackResolver.finiteNonnegative(columnSpacing)
        let named = GridNamedColumns.tracks(columns)
        let plan = named.map { ColumnVisibilityPlan.resolve($0, overrides: columnVisibility, availableWidth: proposal.width ?? .infinity, spacing: gap) }
        let mapping = plan.map { Dictionary(uniqueKeysWithValues: $0.indices.enumerated().map { ($0.element, $0.offset) }) }
        func presentedColumn(_ source: Int) -> Int? {
            if let mapping { return mapping[source] }
            return source
        }
        let visibleColumns = plan.map { plan in plan.indices.map { columns[$0] } } ?? columns
        var intrinsicWidths: [CGFloat] = []
        if proposal.width?.isFinite != true {
            intrinsicWidths = Array(repeating: 0, count: visibleColumns.count)
            for index in subviews.indices {
                let column = index % columns.count
                if let presented = presentedColumn(column) {
                    intrinsicWidths[presented] = max(intrinsicWidths[presented], subviews[index].sizeThatFits(.unspecified).width)
                }
            }
        }
        let widths = GridTrackResolver.widths(columns: visibleColumns, availableWidth: proposal.width,
                                             spacing: gap, intrinsicWidths: intrinsicWidths)
        let sourceColumnCount = named == nil ? widths.count : columns.count
        let rowCount = subviews.count / sourceColumnCount + (subviews.count % sourceColumnCount == 0 ? 0 : 1)
        var heights = Array(repeating: CGFloat.zero, count: rowCount)
        var activeRows = Array(repeating: false, count: rowCount)
        var sizes: [CGSize] = []
        sizes.reserveCapacity(subviews.count)
        for index in subviews.indices {
            let source = index % sourceColumnCount
            let presented = presentedColumn(source)
            let size = presented.map { subviews[index].sizeThatFits(.init(width: widths[$0])) } ?? .zero
            sizes.append(size)
            if presented != nil { activeRows[index / sourceColumnCount] = true }
            heights[index / sourceColumnCount] = max(heights[index / sourceColumnCount], size.height)
        }
        return GridArrangement(widths: widths, heights: heights, itemSizes: sizes,
                               sourceColumnCount: sourceColumnCount, mapping: mapping, activeRows: activeRows,
                               size: CGSize(width: widths.totalWidth,
                                            height: heights.reduce(0, +) + GridTrackResolver.finiteNonnegative(rowSpacing) * CGFloat(max(0, activeRows.filter { $0 }.count - 1))))
    }

    private var alignmentComponents: (horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        switch alignment {
        case .topLeading: return (.leading, .top)
        case .top: return (.center, .top)
        case .topTrailing: return (.trailing, .top)
        case .leading: return (.leading, .center)
        case .center: return (.center, .center)
        case .trailing: return (.trailing, .center)
        case .bottomLeading: return (.leading, .bottom)
        case .bottom: return (.center, .bottom)
        case .bottomTrailing: return (.trailing, .bottom)
        }
    }

    private func horizontalOffset(_ alignment: HorizontalAlignment, available: CGFloat, rtl: Bool) -> CGFloat {
        switch alignment {
        case .leading: return rtl ? available : 0
        case .center: return available / 2
        case .trailing: return rtl ? 0 : available
        }
    }

    private func verticalOffset(_ alignment: VerticalAlignment, available: CGFloat) -> CGFloat {
        switch alignment {
        case .top: return 0
        case .center: return available / 2
        case .bottom: return available
        }
    }
}

private struct GridArrangement {
    let widths: GridTracks
    let heights: [CGFloat]
    let itemSizes: [CGSize]
    let sourceColumnCount: Int
    let mapping: [Int: Int]?
    let activeRows: [Bool]
    let size: CGSize
    func presentedColumn(_ source: Int) -> Int? {
        if let mapping { return mapping[source] }
        return source
    }
    static let empty = GridArrangement(widths: GridTracks(groups: [], spacing: 0), heights: [], itemSizes: [],
        sourceColumnCount: 1, mapping: nil, activeRows: [], size: .zero)
}

/// Places each direct child in one cell. Use `LazyGrid` for large collections.
public struct Grid<Content: View>: View {
    private let layout: GridLayout
    private let content: Content
    private let columnVisibility: Binding<[String: Bool]>?
    private let isEnabled: Bool
    @State private var localVisibility: [String: Bool] = [:]

    public init(columns: [GridColumn], columnSpacing: CGFloat = 0,
                rowSpacing: CGFloat = 0, alignment: Alignment = .topLeading,
                columnVisibility: Binding<[String: Bool]>? = nil, isEnabled: Bool = true,
                @ViewBuilder content: () -> Content) {
        layout = GridLayout(columns: columns, columnSpacing: columnSpacing,
                            rowSpacing: rowSpacing, alignment: alignment)
        self.content = content()
        self.columnVisibility = columnVisibility; self.isEnabled = isEnabled
    }

    public var body: some View {
        ContainerSizeReader { size in
            let overrides = columnVisibility ?? $localVisibility
            var algorithm = layout; algorithm.columnVisibility = overrides.wrappedValue
            return GridInteractionHost(isEnabled: isEnabled) {
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    if let tracks = GridNamedColumns.tracks(layout.columns) {
                        ColumnVisibilityPicker(columns: tracks,
                            plan: .resolve(tracks, overrides: overrides.wrappedValue, availableWidth: size.width,
                                           spacing: GridTrackResolver.finiteNonnegative(layout.columnSpacing)),
                            overrides: overrides, isEnabled: isEnabled).flex(0, shrink: 0)
                    }
                    ScrollView(.horizontal) {
                        algorithm { content }
                            .frame(width: .percent(100), minWidth: Float(GridNamedColumns.minimumWidth(layout.columns,
                                overrides: overrides.wrappedValue, spacing: GridTrackResolver.finiteNonnegative(layout.columnSpacing))))
                            .flex(0, shrink: 0)
                    }.flex(0, shrink: 0)
                }.opacity(isEnabled ? 1 : 0.55)
            }
        }
    }
}
