internal import Foundation

/// Three retained slots: leading glyph, flexible title, trailing controls.
/// Only the title yields width. The measured chrome minimum belongs to the
/// control, so an enclosing maximum can never shrink its chrome.
struct InlineLabelLayout: Layout {
    var spacing: CGFloat = 6
    let onMinimumWidth: (CGFloat) -> Void

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        arrangement(proposal, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        guard subviews.count == 3 else { return }
        let plan = arrangement(.init(width: bounds.width), subviews)
        let rtl = subviews.first?.layoutDirection == .rtl
        var cursor = rtl ? bounds.maxX : bounds.minX
        for index in subviews.indices {
            let size = plan.slots[index]
            let x = rtl ? cursor - size.width : cursor
            subviews[index].place(at: CGPoint(x: x, y: bounds.minY + (bounds.height - size.height) / 2),
                                  proposal: .init(width: size.width, height: size.height))
            let gap: CGFloat = index == 0 ? (size.width > 0 ? spacing : 0) : (index == 1 && plan.slots[2].width > 0 ? spacing : 0)
            cursor += (rtl ? -1 : 1) * (size.width + gap)
        }
        onMinimumWidth(plan.minimumWidth)
    }

    private func arrangement(_ proposal: ProposedViewSize, _ subviews: [LayoutSubview]) -> Plan {
        guard subviews.count == 3 else { return Plan(slots: [], minimumWidth: 0, size: .zero) }
        let leading = subviews[0].sizeThatFits(.unspecified), trailing = subviews[2].sizeThatFits(.unspecified)
        let minimum = leading.width + trailing.width + (leading.width > 0 ? spacing : 0) + (trailing.width > 0 ? spacing : 0)
        let title = subviews[1].sizeThatFits(.init(width: proposal.width.map { max(0, $0 - minimum) }))
        return Plan(slots: [leading, title, trailing], minimumWidth: minimum,
                    size: CGSize(width: minimum + title.width, height: max(leading.height, title.height, trailing.height)))
    }

    private struct Plan {
        let slots: [CGSize]
        let minimumWidth: CGFloat
        let size: CGSize
    }
}
