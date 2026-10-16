internal import Foundation

/// Measurements are pure; publishing the chosen menu happens during placement,
/// just as a container query publishes its final allocated size after layout.
struct ToolbarOverflowLayout: Layout {
    let availableWidth: CGFloat
    let placements: [ToolbarItem.Placement]
    let spacing: CGFloat
    let onOverflow: ([Int]) -> Void
    var onContentWidth: ((CGFloat) -> Void)?
    var fitsContent = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        arrangement(subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        let plan = arrangement(subviews)
        let rtl = subviews.first?.layoutDirection == .rtl
        var cursor = rtl ? bounds.maxX : bounds.minX
        for index in subviews.indices {
            let size = plan.sizes[index]
            guard plan.visible.contains(index) else {
                subviews[index].place(at: CGPoint(x: -1_000_000, y: 0))
                continue
            }
            let x = rtl ? cursor - size.width : cursor
            subviews[index].place(at: CGPoint(x: x, y: bounds.minY + (plan.size.height - size.height) / 2))
            cursor += (rtl ? -1 : 1) * (size.width + spacing)
        }
        onOverflow(plan.hidden)
        onContentWidth?(plan.visible.sorted().reduce(CGFloat(0)) { $0 + plan.sizes[$1].width }
                        + spacing * CGFloat(max(0, plan.visible.count - 1)))
    }

    private func arrangement(_ subviews: [LayoutSubview]) -> Arrangement {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        guard sizes.count == placements.count + 1 else {
            return Arrangement(sizes: sizes, visible: [], hidden: [], size: .zero)
        }
        let more = placements.count
        var hidden = Set(placements.indices.filter { placements[$0] == .overflow })
        func visible() -> [Int] {
            placements.indices.filter { !hidden.contains($0) } + (hidden.isEmpty ? [] : [more])
        }
        func width(_ indices: [Int]) -> CGFloat {
            indices.reduce(0) { $0 + sizes[$1].width } + spacing * CGFloat(max(0, indices.count - 1))
        }
        let candidates = placements.indices.filter {
            if case .automatic = placements[$0] { return true }; return false
        }.sorted { lhs, rhs in
            guard case let .automatic(a) = placements[lhs], case let .automatic(b) = placements[rhs] else { return false }
            return a == b ? lhs > rhs : a < b
        }
        for candidate in candidates where width(visible()) > availableWidth {
            hidden.insert(candidate)
        }
        let shown = visible()
        return Arrangement(sizes: sizes, visible: Set(shown), hidden: hidden.sorted(),
            size: CGSize(width: fitsContent ? width(shown) : max(availableWidth, width(shown)),
                         height: shown.map { sizes[$0].height }.max() ?? 0))
    }

    private struct Arrangement {
        let sizes: [CGSize]
        let visible: Set<Int>
        let hidden: [Int]
        let size: CGSize
    }
}
