internal import Foundation

struct HorizontalScrollOrigin: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(.init(width: proposal.width))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(.init(width: bounds.width))
        let inset = child.layoutDirection == .rtl ? max(0, bounds.width - size.width) : 0
        child.place(at: CGPoint(x: bounds.minX + inset, y: bounds.minY),
                    proposal: .init(width: size.width, height: size.height))
    }
}
