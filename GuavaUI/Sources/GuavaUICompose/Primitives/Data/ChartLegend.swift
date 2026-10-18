import Foundation
import GuavaUIRuntime

/// One named series color in a `ChartLegend`.
public struct ChartLegendItem: Sendable {
    public var title: String
    public var color: SemanticColorRef

    public init(_ title: String, color: SemanticColorRef = .accent) {
        self.title = title
        self.color = color
    }
}

/// A wrapping legend for one or more chart series.
///
/// Items stay on one line when the container is wide enough and wrap as a
/// group when it is not. The colored swatch is decorative; the title remains
/// the readable and accessible name of the item.
public struct ChartLegend: View {
    public let items: [ChartLegendItem]

    public init(items: [ChartLegendItem]) {
        self.items = items.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public init(series: [ChartSeries]) {
        self.init(items: series.compactMap { series in
            let title = series.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title.isEmpty ? nil : ChartLegendItem(title, color: series.color)
        })
    }

    public var body: some View {
        ChartLegendLayout(horizontalSpacing: 8, verticalSpacing: 2) {
            for (index, item) in items.enumerated() {
                ChartLegendItemView(item: item, index: index)
            }
        }
        .frame(minWidth: 0)
    }
}

private struct ChartLegendLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.init(width: 10_000)) }
        guard let width = proposal.width, width.isFinite else {
            let contentWidth = sizes.reduce(0) { $0 + $1.width }
                + horizontalSpacing * CGFloat(max(0, sizes.count - 1))
            return CGSize(width: contentWidth, height: sizes.map(\.height).max() ?? 0)
        }
        let rows = rows(sizes: sizes, width: max(0, width))
        return CGSize(width: max(0, width), height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        guard !subviews.isEmpty else { return }
        let sizes = subviews.map { $0.sizeThatFits(.init(width: 10_000)) }
        let rows = rows(sizes: sizes, width: bounds.width)
        let rtl = subviews.first?.layoutDirection == .rtl
        for index in subviews.indices {
            let size = sizes[index]
            let x = rtl ? bounds.maxX - rows.positions[index].x - size.width : bounds.minX + rows.positions[index].x
            subviews[index].place(at: CGPoint(x: x, y: bounds.minY + rows.positions[index].y),
                                  proposal: .init(width: size.width, height: size.height))
        }
    }

    private func rows(sizes: [CGSize], width: CGFloat) -> (positions: [CGPoint], height: CGFloat) {
        var positions: [CGPoint] = []
        positions.reserveCapacity(sizes.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > width {
                y += rowHeight + verticalSpacing
                x = 0
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }
        return (positions, y + rowHeight)
    }
}

private struct ChartLegendItemView: View {
    let item: ChartLegendItem
    let index: Int

    var body: some View {
        Row(alignment: .center, spacing: 6) {
            Box {}.frame(width: 8, height: 8).background(item.color).cornerRadius(4)
                .accessibilityHidden()
            Text(item.title).font(.caption).foregroundColor(.onSurfaceVariant).flex(0, shrink: 0)
        }
        .padding(horizontal: 2, vertical: 3)
        .flex(0, shrink: 0)
        .accessibility { $0.role = .staticText; $0.label = item.title }
        .debugName("chart-legend-item-\(index)")
    }
}
