import GuavaUIRuntime

/// Repositions the same action nodes across surface and content-size changes.
/// Natural widths decide when a desktop footer also needs to stack.
struct DialogActionsLayout: Layout {
    let stacks: Bool
    private let spacing: CGFloat = 8

    private func vertical(width: CGFloat?, subviews: [LayoutSubview]) -> Bool {
        stacks || width.map { available in
            subviews.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(.unspecified).width }
                + spacing * CGFloat(max(0, subviews.count - 1)) > available
        } == true
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let column = vertical(width: proposal.width, subviews: subviews)
        let sizes = subviews.map { $0.sizeThatFits(column ? .init(width: proposal.width) : .unspecified) }
        let gaps = spacing * CGFloat(max(0, sizes.count - 1))
        let width = column ? sizes.map(\.width).max() ?? 0 : sizes.reduce(0) { $0 + $1.width } + gaps
        let height = column ? sizes.reduce(0) { $0 + $1.height } + gaps : sizes.map(\.height).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        let column = vertical(width: bounds.width, subviews: subviews)
        let sizes = subviews.map { $0.sizeThatFits(column ? .init(width: bounds.width) : .unspecified) }
        let used = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1))
        let rtl = subviews.first?.layoutDirection == .rtl
        var offset: CGFloat = column ? 0 : max(0, bounds.width - used)
        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            let x = column ? (rtl ? 0 : max(0, bounds.width - size.width))
                : (rtl ? bounds.width - offset - size.width : offset)
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + (column ? offset : (bounds.height - size.height) / 2)),
                          // An intrinsic action keeps its unspecified width.
                          // Feeding Yoga its rounded measured width can shave
                          // a fraction off the label and spuriously ellipsize it.
                          proposal: .init(width: column ? bounds.width : nil, height: size.height))
            offset += (column ? size.height : size.width) + spacing
        }
    }
}
