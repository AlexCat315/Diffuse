internal import Foundation
internal import GuavaUIRuntime

/// A single-line title with independent leading and trailing slots. Only the
/// title truncates; complete names remain in semantics and the title tooltip.
/// When the fixed slots alone exceed the viewport, the row scrolls horizontally.
public struct ListRow<Leading: View, Trailing: View>: View {
    private let title: String
    private let leading: Leading
    private let trailing: Trailing

    public init(_ title: String, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.leading = leading(); self.trailing = trailing()
    }

    public var body: some View {
        // The horizontal viewport proposes its own width to the row, so a row
        // mounted mid-scroll is laid out at full width in its first frame.
        TextScalerReader { scaler in
            var scroll = ScrollView(.horizontal) {
                ListRowLayout(minimumTitleWidth: CGFloat(scaler.scale(24))) {
                    Box(direction: .row, alignItems: .center, spacing: 0) { leading }
                    Text(title).truncated()
                    Box(direction: .row, alignItems: .center, spacing: 0) { trailing }
                }
            }
            scroll.combinesAccessibility = true
            return scroll
        }.frame(minWidth: 0)
    }
}

public extension ListRow where Leading == EmptyView {
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.init(title, leading: { EmptyView() }, trailing: trailing)
    }
}

public extension ListRow where Leading == EmptyView, Trailing == EmptyView {
    init(_ title: String) { self.init(title, leading: { EmptyView() }, trailing: { EmptyView() }) }
}

private struct ListRowLayout: Layout {
    let minimumTitleWidth: CGFloat
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        plan(subviews, width: proposal.width).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        guard subviews.count == 3 else { return }
        let plan = plan(subviews, width: bounds.width), rtl = subviews[0].layoutDirection == .rtl
        var x = rtl ? bounds.maxX : bounds.minX
        for index in subviews.indices {
            let size = plan.slots[index]
            // Fixed slots keep the intrinsic proposal used for measurement.
            // Reapplying Yoga's rounded width as an at-most constraint can
            // wrap a badge's last glyph and change its height during placement.
            let slotProposal: ProposedViewSize = index == 1 ? .init(width: size.width, height: size.height) : .unspecified
            subviews[index].place(at: .init(x: rtl ? x - size.width : x, y: bounds.minY + (bounds.height - size.height) / 2),
                                 proposal: slotProposal)
            let gap = index == 0 ? (size.width > 0 ? spacing : 0) : (index == 1 && plan.slots[2].width > 0 ? spacing : 0)
            x += (rtl ? -1 : 1) * (size.width + gap)
        }
    }
    /// `width` is the viewport; nil (unbounded) gives the title its natural width.
    private func plan(_ subviews: [LayoutSubview], width: CGFloat?) -> Plan {
        guard subviews.count == 3 else { return Plan(slots: [], size: .zero) }
        let leading = subviews[0].sizeThatFits(.unspecified), trailing = subviews[2].sizeThatFits(.unspecified)
        let minimum = leading.width + trailing.width + (leading.width > 0 ? spacing : 0) + (trailing.width > 0 ? spacing : 0)
        let natural = minimum + subviews[1].sizeThatFits(.unspecified).width
        let rowWidth = max(width.map { $0.isFinite ? $0 : natural } ?? natural, minimum + minimumTitleWidth)
        let titleWidth = rowWidth - minimum
        let title = subviews[1].sizeThatFits(.init(width: titleWidth))
        return Plan(slots: [leading, CGSize(width: titleWidth, height: title.height), trailing],
                    size: CGSize(width: rowWidth, height: max(leading.height, title.height, trailing.height)))
    }
    private struct Plan { let slots: [CGSize]; let size: CGSize }
}
