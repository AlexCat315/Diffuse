internal import Foundation

/// Equal-width axis fields in one row while each keeps its minimum width;
/// otherwise every axis gets a full-width row. Never splits two and one,
/// which reads as a broken grid. Proposals are at-most, so axes fill them
/// with a 100% width.
struct AxisLayout: Layout {
    var spacing: CGFloat = 4
    var minimumWidth: CGFloat
    /// Per-axis width when the container proposes none.
    var idealWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        let plan = arrangement(proposal.width, subviews)
        return plan.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        let plan = arrangement(bounds.width, subviews)
        for (index, subview) in subviews.enumerated() {
            let frame = plan.frames[index]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: .init(width: frame.width, height: frame.height))
        }
    }

    private func arrangement(_ width: CGFloat?, _ subviews: [LayoutSubview]) -> (frames: [CGRect], size: CGSize) {
        guard !subviews.isEmpty else { return ([], .zero) }
        let count = CGFloat(subviews.count), gaps = spacing * (count - 1)
        let available = width ?? (idealWidth * count + gaps)
        if available >= minimumWidth * count + gaps {
            let column = (available - gaps) / count
            let heights = subviews.map { $0.sizeThatFits(.init(width: column)).height }
            let height = heights.max() ?? 0
            let frames = subviews.indices.map { CGRect(x: CGFloat($0) * (column + spacing), y: 0, width: column, height: height) }
            return (frames, CGSize(width: available, height: height))
        }
        var y: CGFloat = 0
        let frames = subviews.map { subview -> CGRect in
            let height = subview.sizeThatFits(.init(width: available)).height
            defer { y += height + spacing }
            return CGRect(x: 0, y: y, width: available, height: height)
        }
        return (frames, CGSize(width: available, height: max(0, y - spacing)))
    }
}
