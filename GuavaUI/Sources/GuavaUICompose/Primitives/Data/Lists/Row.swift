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
        ContainerSizeReader { size in
            TextScalerReader { scaler in
                var scroll = ScrollView(.horizontal) {
                    ListRowLayout(width: size.width, minimumTitleWidth: CGFloat(scaler.scale(24))) {
                        Box(direction: .row, alignItems: .center, spacing: 0) { leading }
                        Text(title).truncated()
                        Box(direction: .row, alignItems: .center, spacing: 0) { trailing }
                    }
                }
                scroll.combinesAccessibility = true
                return scroll
            }
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
    let width: CGFloat
    let minimumTitleWidth: CGFloat
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        plan(subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        guard subviews.count == 3 else { return }
        let plan = plan(subviews), rtl = subviews[0].layoutDirection == .rtl
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
    private func plan(_ subviews: [LayoutSubview]) -> Plan {
        guard subviews.count == 3 else { return Plan(slots: [], size: .zero) }
        let leading = subviews[0].sizeThatFits(.unspecified), trailing = subviews[2].sizeThatFits(.unspecified)
        let minimum = leading.width + trailing.width + (leading.width > 0 ? spacing : 0) + (trailing.width > 0 ? spacing : 0)
        let rowWidth = max(width, minimum + minimumTitleWidth)
        let titleWidth = rowWidth - minimum
        let title = subviews[1].sizeThatFits(.init(width: titleWidth))
        return Plan(slots: [leading, CGSize(width: titleWidth, height: title.height), trailing],
                    size: CGSize(width: rowWidth, height: max(leading.height, title.height, trailing.height)))
    }
    private struct Plan { let slots: [CGSize]; let size: CGSize }
}
