import Foundation

/// A general row-major grid built on the public measurement and placement
/// contract. Row heights come from the tallest measured child in each row.
/// Cells do not span rows or columns.
public struct GridLayout: Layout {
    public var columns: [GridColumn]
    public var columnSpacing: CGFloat = 0
    public var rowSpacing: CGFloat = 0
    public var alignment: Alignment = .topLeading

    public init(columns: [GridColumn], columnSpacing: CGFloat = 0,
                rowSpacing: CGFloat = 0, alignment: Alignment = .topLeading) {
        self.columns = columns
        self.columnSpacing = columnSpacing
        self.rowSpacing = rowSpacing
        self.alignment = alignment
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        arrangement(proposal: proposal, subviews: subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        let arrangement = arrangement(proposal: .init(width: bounds.width), subviews: subviews)
        guard !arrangement.widths.isEmpty else { return }
        let gap = GridTrackResolver.finiteNonnegative(columnSpacing)
        let rowGap = GridTrackResolver.finiteNonnegative(rowSpacing)
        let rtl = subviews.first?.layoutDirection == .rtl
        let components = alignmentComponents
        var y = bounds.minY
        var row = 0
        var x: CGFloat = 0
        for index in subviews.indices {
            let column = index % arrangement.widths.count
            if column == 0 { x = 0 }
            let cellWidth = arrangement.widths[column]
            let itemSize = arrangement.itemSizes[index]
            let horizontal = horizontalOffset(components.horizontal, available: cellWidth - itemSize.width, rtl: rtl)
            let vertical = verticalOffset(components.vertical, available: arrangement.heights[row] - itemSize.height)
            let cellX = rtl ? bounds.maxX - x - cellWidth : bounds.minX + x
            subviews[index].place(at: CGPoint(x: cellX + horizontal, y: y + vertical),
                                  proposal: .init(width: cellWidth, height: itemSize.height))
            x += cellWidth + gap
            if column + 1 == arrangement.widths.count || index + 1 == subviews.count {
                y += arrangement.heights[row] + rowGap
                row += 1
            }
        }
    }

    private func arrangement(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> GridArrangement {
        guard !columns.isEmpty, !subviews.isEmpty else { return .empty }
        let gap = GridTrackResolver.finiteNonnegative(columnSpacing)
        var intrinsicWidths: [CGFloat] = []
        if proposal.width?.isFinite != true {
            intrinsicWidths = Array(repeating: 0, count: columns.count)
            for index in subviews.indices {
                let column = index % columns.count
                intrinsicWidths[column] = max(intrinsicWidths[column], subviews[index].sizeThatFits(.unspecified).width)
            }
        }
        let widths = GridTrackResolver.widths(columns: columns, availableWidth: proposal.width,
                                             spacing: gap, intrinsicWidths: intrinsicWidths)
        let rowCount = subviews.count / widths.count + (subviews.count % widths.count == 0 ? 0 : 1)
        var heights = Array(repeating: CGFloat.zero, count: rowCount)
        var sizes: [CGSize] = []
        sizes.reserveCapacity(subviews.count)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.init(width: widths[index % widths.count]))
            sizes.append(size)
            heights[index / widths.count] = max(heights[index / widths.count], size.height)
        }
        return GridArrangement(widths: widths, heights: heights, itemSizes: sizes,
                               size: CGSize(width: widths.totalWidth,
                                            height: heights.reduce(0, +) + GridTrackResolver.finiteNonnegative(rowSpacing) * CGFloat(heights.count - 1)))
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
    let size: CGSize
    static let empty = GridArrangement(widths: GridTracks(groups: [], spacing: 0), heights: [], itemSizes: [], size: .zero)
}

/// Places each direct child in one cell. Use `LazyGrid` for large collections.
public struct Grid<Content: View>: View {
    private let layout: GridLayout
    private let content: Content

    public init(columns: [GridColumn], columnSpacing: CGFloat = 0,
                rowSpacing: CGFloat = 0, alignment: Alignment = .topLeading,
                @ViewBuilder content: () -> Content) {
        layout = GridLayout(columns: columns, columnSpacing: columnSpacing,
                            rowSpacing: rowSpacing, alignment: alignment)
        self.content = content()
    }

    public var body: some View { layout { content } }
}
