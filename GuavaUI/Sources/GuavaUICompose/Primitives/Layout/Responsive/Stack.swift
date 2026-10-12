import Foundation

/// A natural-size stack algorithm for use in custom and candidate layouts.
/// Children receive the offered cross-axis size and an intrinsic main axis;
/// use Box/Row/Column when flex growth or compression is required.
public struct StackLayout: Layout {
    public enum Axis: Sendable { case horizontal, vertical }

    public var axis: Axis = .vertical
    public var spacing: CGFloat = 0
    public var alignment: Alignment = .topLeading

    public init(_ axis: Axis = .vertical, spacing: CGFloat = 0,
                alignment: Alignment = .topLeading) {
        self.axis = axis
        self.spacing = spacing
        self.alignment = alignment
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        arrangement(proposal: proposal, subviews: subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        let offered = ProposedViewSize(width: bounds.width, height: bounds.height)
        let arrangement = arrangement(proposal: offered, subviews: subviews)
        let childProposal = proposalForChild(offered)
        let rtl = subviews.first?.layoutDirection == .rtl
        let parts = alignmentComponents
        let startX = bounds.minX + horizontalOffset(parts.horizontal,
                                                   available: bounds.width - arrangement.size.width, rtl: rtl)
        let startY = bounds.minY + verticalOffset(parts.vertical,
                                                 available: bounds.height - arrangement.size.height)
        var cursor: CGFloat = 0
        for index in subviews.indices {
            let size = arrangement.children[index]
            let point: CGPoint
            switch axis {
            case .horizontal:
                let x = rtl ? startX + arrangement.size.width - cursor - size.width : startX + cursor
                let y = bounds.minY + verticalOffset(parts.vertical, available: bounds.height - size.height)
                point = CGPoint(x: x, y: y)
                cursor += size.width + resolvedSpacing
            case .vertical:
                let x = bounds.minX + horizontalOffset(parts.horizontal, available: bounds.width - size.width, rtl: rtl)
                point = CGPoint(x: x, y: startY + cursor)
                cursor += size.height + resolvedSpacing
            }
            // A measured size can be rounded by the layout engine. Treating
            // that result as a new, tighter constraint can wrap the final
            // character and change the child's height during placement.
            subviews[index].place(at: point, proposal: childProposal)
        }
    }

    private var resolvedSpacing: CGFloat { spacing.isFinite ? max(0, spacing) : 0 }

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

    private func arrangement(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> StackArrangement {
        let childProposal = proposalForChild(proposal)
        let sizes = subviews.map { $0.sizeThatFits(childProposal) }
        var main: CGFloat = resolvedSpacing * CGFloat(max(0, sizes.count - 1))
        var cross: CGFloat = 0
        for size in sizes {
            switch axis {
            case .horizontal: main += size.width; cross = max(cross, size.height)
            case .vertical: main += size.height; cross = max(cross, size.width)
            }
        }
        let size: CGSize
        switch axis {
        case .horizontal: size = CGSize(width: main, height: cross)
        case .vertical: size = CGSize(width: cross, height: main)
        }
        return StackArrangement(children: sizes, size: size)
    }

    private func proposalForChild(_ proposal: ProposedViewSize) -> ProposedViewSize {
        switch axis {
        case .horizontal: return .init(height: proposal.height)
        case .vertical: return .init(width: proposal.width)
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

private struct StackArrangement {
    let children: [CGSize]
    let size: CGSize
}
