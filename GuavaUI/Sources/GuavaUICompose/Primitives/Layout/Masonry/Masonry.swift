import Foundation
import GuavaUIRuntime

/// A balanced waterfall layout: each child is measured at the column width and
/// placed in the currently shortest column. Rows are not fixed, so cards with
/// different heights pack without leaving the vertical gaps a row grid leaves.
///
/// The layout itself owns only geometry. It does not virtualize children: use
/// `LazyGrid` for large fixed-height collections and `VirtualStack` for large
/// known-height lists.
public struct MasonryLayout: Layout {
    public var minimumColumnWidth: CGFloat
    public var maximumColumns: Int
    public var columnSpacing: CGFloat
    public var itemSpacing: CGFloat
    /// Horizontal alignment of a child inside its column. The vertical
    /// component is ignored because every column places children back to back.
    public var alignment: Alignment

    public init(minimumColumnWidth: CGFloat = 160,
                maximumColumns: Int = 2,
                columnSpacing: CGFloat = 12,
                itemSpacing: CGFloat = 12,
                alignment: Alignment = .topLeading) {
        self.minimumColumnWidth = minimumColumnWidth.isFinite ? max(1, minimumColumnWidth) : 160
        self.maximumColumns = min(8, max(1, maximumColumns))
        self.columnSpacing = columnSpacing.isFinite ? max(0, columnSpacing) : 12
        self.itemSpacing = itemSpacing.isFinite ? max(0, itemSpacing) : 12
        self.alignment = alignment
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        arrangement(proposal: proposal, subviews: subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        guard !subviews.isEmpty else { return }
        let arrangement = arrangement(proposal: .init(width: bounds.width), subviews: subviews)
        guard arrangement.columnCount > 0 else { return }
        let rtl = subviews.first?.layoutDirection == .rtl
        let components = alignmentComponents
        for index in subviews.indices {
            let column = arrangement.columns[index]
            let item = arrangement.sizes[index]
            let columnWidth = arrangement.columnWidth
            let cellX = rtl
                ? bounds.maxX - CGFloat(column) * (columnWidth + columnSpacing) - columnWidth
                : bounds.minX + CGFloat(column) * (columnWidth + columnSpacing)
            let available = max(0, columnWidth - item.width)
            let x = cellX + horizontalOffset(components.horizontal, available: available, rtl: rtl)
            subviews[index].place(at: CGPoint(x: x, y: bounds.minY + arrangement.offsets[index]),
                                  proposal: .init(width: columnWidth, height: item.height))
        }
    }

    private func arrangement(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> MasonryArrangement {
        guard !subviews.isEmpty else { return .empty }
        let availableWidth = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
        let columnCount = columnCount(for: availableWidth)
        let columnWidth: CGFloat
        let sizes: [CGSize]
        if let availableWidth {
            columnWidth = max(0, (availableWidth - columnSpacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
            sizes = subviews.map { measured($0, width: columnWidth) }
        } else {
            let intrinsic = subviews.map { measured($0, width: nil).width }
            columnWidth = intrinsic.max() ?? 0
            sizes = subviews.map { measured($0, width: columnWidth) }
        }

        var heights = [CGFloat](repeating: 0, count: columnCount)
        var offsets = [CGFloat](repeating: 0, count: subviews.count)
        var columns = [Int](repeating: 0, count: subviews.count)
        for index in subviews.indices {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[index] = column
            offsets[index] = heights[column]
            heights[column] += sizes[index].height + itemSpacing
        }
        let contentHeight = max(0, (heights.max() ?? 0) - itemSpacing)
        let contentWidth = columnWidth * CGFloat(columnCount)
            + columnSpacing * CGFloat(max(0, columnCount - 1))
        return MasonryArrangement(columnCount: columnCount,
                                  columnWidth: columnWidth,
                                  columns: columns,
                                  sizes: sizes,
                                  offsets: offsets,
                                  size: CGSize(width: contentWidth, height: contentHeight))
    }

    private func columnCount(for availableWidth: CGFloat?) -> Int {
        guard let availableWidth else { return maximumColumns }
        let fit = Int(floor((availableWidth + columnSpacing) / (minimumColumnWidth + columnSpacing)))
        return min(maximumColumns, max(1, fit))
    }

    private func measured(_ subview: LayoutSubview, width: CGFloat?) -> CGSize {
        let size = subview.sizeThatFits(.init(width: width))
        return CGSize(width: size.width.isFinite ? max(0, size.width) : 0,
                      height: size.height.isFinite ? max(0, size.height) : 0)
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
}

private struct MasonryArrangement {
    let columnCount: Int
    let columnWidth: CGFloat
    let columns: [Int]
    let sizes: [CGSize]
    let offsets: [CGFloat]
    let size: CGSize
    static let empty = MasonryArrangement(columnCount: 0, columnWidth: 0, columns: [], sizes: [],
                                          offsets: [], size: .zero)
}

/// Convenience wrapper around `MasonryLayout`.
///
/// ```swift
/// Masonry(minimumColumnWidth: 200, maximumColumns: 2, itemSpacing: 12) {
///     ForEach(cards) { CardView(card: $0) }
/// }
/// ```
public struct Masonry<Content: View>: View {
    private let layout: MasonryLayout
    private let content: Content

    public init(minimumColumnWidth: CGFloat = 160,
                maximumColumns: Int = 2,
                columnSpacing: CGFloat = 12,
                itemSpacing: CGFloat = 12,
                alignment: Alignment = .topLeading,
                @ViewBuilder content: () -> Content) {
        layout = MasonryLayout(minimumColumnWidth: minimumColumnWidth,
                               maximumColumns: maximumColumns,
                               columnSpacing: columnSpacing,
                               itemSpacing: itemSpacing,
                               alignment: alignment)
        self.content = content()
    }

    public var body: some View {
        layout { content }
    }
}
