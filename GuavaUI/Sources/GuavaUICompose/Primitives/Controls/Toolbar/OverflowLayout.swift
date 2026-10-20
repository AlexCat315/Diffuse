internal import Foundation

/// Measurements are pure; publishing the chosen menu happens during placement,
/// just as a container query publishes its final allocated size after layout.
/// The main axis follows the toolbar: widths for a horizontal bar, heights for
/// a vertical one.
struct ToolbarOverflowLayout: Layout {
    let availableExtent: CGFloat
    let placements: [ToolbarItem.Placement]
    let spacing: CGFloat
    let onOverflow: ([Int]) -> Void
    var onContentExtent: ((CGFloat) -> Void)?
    var fitsContent = false
    var axis: ToolbarAxis = .horizontal

    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        arrangement(subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        let plan = arrangement(subviews)
        let rtl = subviews.first?.layoutDirection == .rtl
        let reversed = axis == .horizontal && rtl
        var cursor = axis == .vertical ? bounds.minY : reversed ? bounds.maxX : bounds.minX
        for index in subviews.indices {
            let size = plan.sizes[index]
            guard plan.visible.contains(index) else {
                subviews[index].place(at: CGPoint(x: -1_000_000, y: 0))
                continue
            }
            if axis == .vertical {
                subviews[index].place(at: CGPoint(x: bounds.minX + (plan.size.width - size.width) / 2, y: cursor))
                cursor += size.height + spacing
            } else {
                let x = reversed ? cursor - size.width : cursor
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + (plan.size.height - size.height) / 2))
                cursor += (reversed ? -1 : 1) * (size.width + spacing)
            }
        }
        onOverflow(plan.hidden)
        onContentExtent?(plan.visible.sorted().reduce(CGFloat(0)) { $0 + main(plan.sizes[$1]) }
                        + spacing * CGFloat(max(0, plan.visible.count - 1)))
    }

    private func main(_ size: CGSize) -> CGFloat { axis == .vertical ? size.height : size.width }
    private func cross(_ size: CGSize) -> CGFloat { axis == .vertical ? size.width : size.height }

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
        func extent(_ indices: [Int]) -> CGFloat {
            indices.reduce(0) { $0 + main(sizes[$1]) } + spacing * CGFloat(max(0, indices.count - 1))
        }
        let candidates = placements.indices.filter {
            if case .automatic = placements[$0] { return true }; return false
        }.sorted { lhs, rhs in
            guard case let .automatic(a) = placements[lhs], case let .automatic(b) = placements[rhs] else { return false }
            return a == b ? lhs > rhs : a < b
        }
        for candidate in candidates where extent(visible()) > availableExtent {
            hidden.insert(candidate)
        }
        let shown = visible()
        let length = fitsContent ? extent(shown) : max(availableExtent, extent(shown))
        let thickness = shown.map { cross(sizes[$0]) }.max() ?? 0
        return Arrangement(sizes: sizes, visible: Set(shown), hidden: hidden.sorted(),
            size: axis == .vertical ? CGSize(width: thickness, height: length) : CGSize(width: length, height: thickness))
    }

    private struct Arrangement {
        let sizes: [CGSize]
        let visible: Set<Int>
        let hidden: [Int]
        let size: CGSize
    }
}
