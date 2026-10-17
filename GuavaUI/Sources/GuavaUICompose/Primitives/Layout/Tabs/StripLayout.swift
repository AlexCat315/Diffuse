internal import Foundation

/// Measures the same retained headers for both the strip and menu policy.
/// Only the selected header may shrink; its non-text chrome stays intact.
struct TabOverflowLayout: Layout {
    let selectedIndex: Int?
    let spacing: CGFloat
    let onHidden: ([Int]) -> Void

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        arrangement(proposal, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        let plan = arrangement(.init(width: bounds.width), subviews)
        let rtl = subviews.first?.layoutDirection == .rtl
        var cursor = rtl ? bounds.maxX : bounds.minX
        for index in subviews.indices {
            guard plan.visible.contains(index) else {
                subviews[index].place(at: .zero, proposal: .zero, isVisible: false)
                continue
            }
            let size = plan.sizes[index]
            let x = rtl ? cursor - size.width : cursor
            subviews[index].place(at: CGPoint(x: x, y: bounds.minY + (plan.size.height - size.height) / 2),
                                  proposal: .init(width: size.width, height: size.height))
            cursor += (rtl ? -1 : 1) * (size.width + spacing)
        }
        onHidden(plan.hidden)
    }

    private func arrangement(_ proposal: ProposedViewSize, _ subviews: [LayoutSubview]) -> Plan {
        var sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let count = max(0, sizes.count - 1)
        guard count > 0 else { return Plan(sizes: sizes, visible: [], hidden: [], size: .zero) }
        func width(_ indices: Set<Int>) -> CGFloat {
            indices.reduce(0) { $0 + sizes[$1].width } + spacing * CGFloat(max(0, indices.count - 1))
        }
        let all = Set(0..<count)
        let available = proposal.width ?? width(all)
        var visible = all
        if width(all) > available {
            let selected = selectedIndex.flatMap { all.contains($0) ? $0 : nil } ?? 0
            let moreWidth = count > 1 ? sizes[count].width + spacing : 0
            sizes[selected] = subviews[selected].sizeThatFits(.init(width: max(44, available - moreWidth)))
            visible = [selected]
            if count > 1 { visible.insert(count) }
            for index in 0..<count where index != selected {
                let candidate = visible.union([index])
                if width(candidate) <= available { visible = candidate }
            }
        }
        let hidden = (0..<count).filter { !visible.contains($0) }
        return Plan(sizes: sizes, visible: visible, hidden: hidden,
                    size: CGSize(width: max(available, width(visible)), height: visible.map { sizes[$0].height }.max() ?? 0))
    }

    private struct Plan {
        let sizes: [CGSize]
        let visible: Set<Int>
        let hidden: [Int]
        let size: CGSize
    }
}
