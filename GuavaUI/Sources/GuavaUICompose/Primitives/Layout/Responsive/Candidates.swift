import Foundation

/// Selects the first layout whose measured size fits every specified proposal
/// axis. The last candidate is the fallback even when it overflows.
///
/// All candidates measure and place the same subviews. Changing the selected
/// layout preserves the child tree, identity, focus, and local state.
public struct LayoutThatFits: Layout {
    private let candidates: [any Layout]

    public init(_ candidates: [any Layout]) {
        precondition(!candidates.isEmpty, "LayoutThatFits requires at least one candidate")
        self.candidates = candidates
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        selection(proposal: proposal, subviews: subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: [LayoutSubview]) {
        let actual = ProposedViewSize(width: bounds.width, height: bounds.height)
        let selected = selection(proposal: actual, subviews: subviews)
        candidates[selected.index].placeSubviews(in: bounds, proposal: actual, subviews: subviews)
    }

    private func selection(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> (index: Int, size: CGSize) {
        var lastSize = CGSize.zero
        for index in candidates.indices {
            let size = candidates[index].sizeThatFits(proposal: proposal, subviews: subviews)
            lastSize = size
            if fits(size.width, in: proposal.width), fits(size.height, in: proposal.height) {
                return (index, size)
            }
        }
        return (candidates.count - 1, lastSize)
    }

    private func fits(_ extent: CGFloat, in available: CGFloat?) -> Bool {
        extent.isFinite && extent >= 0 && (available.map { extent <= $0 } ?? true)
    }
}
