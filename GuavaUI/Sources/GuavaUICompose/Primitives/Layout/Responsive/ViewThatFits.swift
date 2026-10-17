import Foundation
import GuavaUIRuntime

/// Selects wide or compact content using the allocated container width.
/// Each branch is created on first selection and retains its own identity and
/// local state until this container is removed. Inactive branches remain mounted
/// but take no layout space, paint no pixels and receive no input or accessibility.
/// App-owned drafts can still use shared bindings across the two presentations.
/// Selection can use an explicit width threshold or measure the wide branch's
/// intrinsic size. Intrinsic mode mounts both branches immediately so it can
/// measure them; hidden branches still stop paint, input and accessibility.
public struct ViewThatFits<Wide: View, Compact: View>: View {
    public enum Mode: Sendable, Equatable {
        case threshold(CGFloat)
        case intrinsic
    }

    private let mode: Mode
    private let wide: () -> Wide
    private let compact: () -> Compact

    public init(threshold: CGFloat = CGFloat(UIEnvironment.Viewport.compactMaximumWidth),
                @ViewBuilder wide: @escaping () -> Wide,
                @ViewBuilder compact: @escaping () -> Compact) {
        self.init(fitting: .threshold(threshold), wide: wide, compact: compact)
    }

    /// `intrinsic` selects wide while its measured natural width/height fit;
    /// otherwise compact. Measurement uses an unspecified proposal so a parent
    /// width cannot make a wrapping wide branch look like it fits.
    public init(fitting mode: Mode,
                @ViewBuilder wide: @escaping () -> Wide,
                @ViewBuilder compact: @escaping () -> Compact) {
        switch mode {
        case .threshold(let value):
            self.mode = .threshold(value.isFinite ? max(0, value) : 0)
        case .intrinsic:
            self.mode = .intrinsic
        }
        self.wide = wide; self.compact = compact
    }

    @ViewBuilder public var body: some View {
        switch mode {
        case .threshold(let threshold):
            ContainerSizeReader { size in
                Box(direction: .column, alignItems: .stretch) {
                    RetainedResponsiveBranch(isActive: size.width >= threshold, content: wide).id("wide")
                    RetainedResponsiveBranch(isActive: size.width < threshold, content: compact).id("compact")
                }
            }
        case .intrinsic:
            IntrinsicFittingLayout() {
                wide()
                compact()
            }
        }
    }
}

private struct IntrinsicFittingLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: [LayoutSubview]) -> CGSize {
        guard let wide = subviews.first else { return .zero }
        let natural = wide.sizeThatFits(ProposedViewSize(width: nil, height: nil))
        let fitsWidth = proposal.width.map { natural.width <= $0 + 0.5 } ?? true
        let fitsHeight = proposal.height.map { natural.height <= $0 + 0.5 } ?? true
        if fitsWidth, fitsHeight { return wide.sizeThatFits(proposal) }
        return (subviews.count > 1 ? subviews[1] : wide).sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: [LayoutSubview]) {
        guard let wide = subviews.first else { return }
        let natural = wide.sizeThatFits(ProposedViewSize(width: nil, height: nil))
        let fitsWidth = natural.width <= bounds.width + 0.5
        let fitsHeight = natural.height <= bounds.height + 0.5
        let chosen = fitsWidth && fitsHeight ? 0 : min(1, subviews.count - 1)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: bounds.origin,
                          proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
                          isVisible: index == chosen)
        }
    }
}

private struct RetainedResponsiveBranch<Content: View>: _PrimitiveView {
    let isActive: Bool
    let content: () -> Content
    private static var activatedKey: String { "__responsiveBranchActivated" }
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode(); layout.alignItems = .stretch
        return layout
    }
    func _updateNode(_ node: Node) {
        if isActive { node.attachments[Self.activatedKey] = true }
        node.isInteractionEnabled = isActive
        node.opacity = isActive ? 1 : 0
        node.layoutNode?.display = isActive ? .flex : .none
        if !isActive {
            if let focused = FocusChainHolder.current?.focused, contains(focused, in: node) { FocusChainHolder.current?.clear() }
            if let captured = PointerCaptureHolder.current?.target, contains(captured, in: node) { PointerCaptureHolder.current?.release() }
        }
    }
    func _children(for node: Node) -> [any View] {
        node.attachments[Self.activatedKey] as? Bool == true ? [content()] : []
    }
    private func contains(_ candidate: Node, in ancestor: Node) -> Bool {
        var current: Node? = candidate
        while let node = current {
            if node === ancestor { return true }
            current = node.parent
        }
        return false
    }
}
