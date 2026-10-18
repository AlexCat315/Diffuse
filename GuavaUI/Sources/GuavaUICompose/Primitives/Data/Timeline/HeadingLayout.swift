internal import Foundation

/// Repositions the same title and metadata nodes using their actual allocation.
/// Neither text is truncated or scaled down to make the heading fit.
struct TimelineHeadingLayout: Layout {
    let spacing: Float

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        plan(proposal, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        let plan = plan(.init(width: bounds.width), subviews)
        let rtl = subviews.first?.layoutDirection == .rtl
        for index in subviews.indices {
            let size = plan.slots[index]
            let x: CGFloat
            let y: CGFloat
            if plan.stacked {
                x = rtl ? bounds.maxX - size.width : bounds.minX
                y = bounds.minY + (index == 0 ? 0 : plan.slots[0].height + 4)
            } else {
                let trailing = index > 0
                x = trailing != rtl ? bounds.maxX - size.width : bounds.minX
                y = bounds.minY + (bounds.height - size.height) / 2
            }
            subviews[index].place(at: .init(x: x, y: y), proposal: .init(width: size.width, height: size.height))
        }
    }

    private func plan(_ proposal: ProposedViewSize, _ subviews: [LayoutSubview]) -> Plan {
        guard !subviews.isEmpty else { return Plan(slots: [], size: .zero, stacked: false) }
        let natural = subviews.map { $0.sizeThatFits(.unspecified) }
        let gap = subviews.count > 1 ? CGFloat(spacing) : 0
        let width = max(0, proposal.width ?? (natural.reduce(0) { $0 + $1.width } + gap))
        let stacked = subviews.count > 1 && (width < 600 || natural.reduce(0) { $0 + $1.width } + gap > width)
        if stacked {
            let slots = subviews.map { $0.sizeThatFits(.init(width: width)) }
            return Plan(slots: slots, size: .init(width: width, height: slots.reduce(0) { $0 + $1.height } + 4), stacked: true)
        }
        let trailingWidth = natural.dropFirst().reduce(0) { $0 + $1.width }
        let title = subviews[0].sizeThatFits(.init(width: max(0, width - trailingWidth - gap)))
        let slots = [title] + natural.dropFirst()
        return Plan(slots: slots, size: .init(width: width, height: slots.map(\.height).max() ?? 0), stacked: false)
    }

    private struct Plan {
        let slots: [CGSize]
        let size: CGSize
        let stacked: Bool
    }
}
