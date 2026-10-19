internal import Foundation
import GuavaUIRuntime

struct ChartLegendItem {
    let title: String
    let color: SemanticColorRef
}

/// Wrapping legend whose items toggle series visibility. Items stay on one
/// line when there is room and wrap whole; a hidden item keeps its place,
/// dims, and shows a hollow swatch.
struct ChartLegend: View {
    let items: [ChartLegendItem]
    let hidden: Binding<Set<String>>

    var body: some View {
        ChartLegendLayout(horizontalSpacing: 4, verticalSpacing: 2) {
            for (index, item) in items.enumerated() {
                ChartLegendToggle(item: item, index: index, isHidden: hidden.wrappedValue.contains(item.title), toggle: { toggle(item.title) })
            }
        }
        .frame(minWidth: 0)
    }

    private func toggle(_ title: String) {
        var next = hidden.wrappedValue
        if next.remove(title) == nil { next.insert(title) }
        hidden.wrappedValue = next
    }
}

private struct ChartLegendToggle: View {
    let item: ChartLegendItem
    let index: Int
    let isHidden: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Row(alignment: .center, spacing: 6) {
                Box {}.frame(width: 8, height: 8)
                    .background(isHidden ? .clear : item.color)
                    .border(isHidden ? .onSurfaceMuted : item.color, width: 1.5)
                    .cornerRadius(4)
                    .accessibilityHidden()
                Text(item.title).lineLimit(1).font(.caption)
                    .foregroundColor(isHidden ? .onSurfaceDisabled : .onSurfaceVariant)
            }
        }
        .buttonStyle(.ghost)
        .controlSize(.small)
        .accessibility {
            $0.role = .toggle; $0.label = item.title
            $0.value = isHidden ? "Hidden" : "Shown"; $0.state.isSelected = !isHidden
        }
        .flex(0, shrink: 0)
        .debugName("chart-legend-item-\(index)")
    }
}

/// Places whole items left to right and wraps; RTL starts at the trailing edge.
struct ChartLegendLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.init(width: 10_000)) }
        guard let width = proposal.width, width.isFinite else {
            let contentWidth = sizes.reduce(0) { $0 + $1.width } + horizontalSpacing * CGFloat(max(0, sizes.count - 1))
            return CGSize(width: contentWidth, height: sizes.map(\.height).max() ?? 0)
        }
        return CGSize(width: max(0, width), height: rows(sizes: sizes, width: max(0, width)).height)
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
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > width { y += rowHeight + verticalSpacing; x = 0; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }
        return (positions, y + rowHeight)
    }
}

/// Positions one callout above an anchor point, inside the plot bounds;
/// it flips below the point when there is no room above.
struct ChartCalloutLayout: Layout {
    let anchorX: CGFloat
    let anchorY: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        guard let callout = subviews.first else { return }
        let size = callout.sizeThatFits(.unspecified)
        let gap: CGFloat = 10
        var x = bounds.minX + anchorX - size.width / 2
        x = max(bounds.minX, min(x, bounds.maxX - size.width))
        var y = bounds.minY + anchorY - gap - size.height
        if y < bounds.minY { y = bounds.minY + anchorY + gap }
        y = max(bounds.minY, min(y, bounds.maxY - size.height))
        callout.place(at: CGPoint(x: x, y: y), proposal: .init(width: size.width, height: size.height))
    }
}
