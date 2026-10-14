import Foundation
import GuavaUIRuntime

/// Selects wide or compact content using the allocated container width.
/// Each branch is created on first selection and retains its own identity and
/// local state until this container is removed. Inactive branches remain mounted
/// but take no layout space, paint no pixels and receive no input or accessibility.
/// App-owned drafts can still use shared bindings across the two presentations.
/// This is a width-threshold selector; it does not measure intrinsic content fit.
public struct ViewThatFits<Wide: View, Compact: View>: View {
    private let threshold: CGFloat
    private let wide: () -> Wide
    private let compact: () -> Compact

    public init(threshold: CGFloat = CGFloat(UIEnvironment.Viewport.compactMaximumWidth),
                @ViewBuilder wide: @escaping () -> Wide,
                @ViewBuilder compact: @escaping () -> Compact) {
        self.threshold = threshold.isFinite ? max(0, threshold) : 0
        self.wide = wide; self.compact = compact
    }

    public var body: some View {
        ContainerSizeReader { size in
            Box(direction: .column, alignItems: .stretch) {
                RetainedResponsiveBranch(isActive: size.width >= threshold, content: wide).id("wide")
                RetainedResponsiveBranch(isActive: size.width < threshold, content: compact).id("compact")
            }
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
