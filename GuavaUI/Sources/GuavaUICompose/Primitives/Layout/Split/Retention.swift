import GuavaUIRuntime

final class SplitFocusTransfer {
    var pendingVisibility: Bool?
}

struct SplitContainerMarker: ViewModifier {
    static let key = "GuavaUI.split.container"
    static let paneKey = "GuavaUI.split.pane"
    func apply(node: Node) { node.attachments[Self.key] = true }
}

/// Keep each pane at the same composition position across compact and wide layouts.
struct SplitRetainedRegion<Content: View>: _PrimitiveView {
    let isVisible: Bool
    let focus: SplitFocusTransfer
    var pane: SplitPane?
    var direction: FlexDirection = .column
    @ViewBuilder let content: Content

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        return node
    }
    func _makeLayoutNode() -> LayoutNode? {
        LayoutNode()
    }
    func _updateLayout(_ layout: LayoutNode) {
        layout.alignItems = .stretch
        layout.flexDirection = direction
    }
    func _updateNode(_ node: Node) {
        node.attachments[SplitContainerMarker.paneKey] = pane
        node.isInteractionEnabled = isVisible
        node.opacity = isVisible ? 1 : 0
        node.accessibility = AccessibilitySemantics(.group) { $0.isHidden = !isVisible }
        node.layoutNode?.display = isVisible ? .flex : .none
        guard !isVisible else { return }
        if let focused = FocusChainHolder.current?.focused, contains(focused, in: node) {
            focus.pendingVisibility = FocusChainHolder.current?.isFocusVisible ?? true
            FocusChainHolder.current?.clear()
        }
        if let captured = PointerCaptureHolder.current?.target, contains(captured, in: node) {
            PointerCaptureHolder.current?.release()
        }
    }
    var _children: [any View] { [content] }
}

struct SplitFocusHandoff: ViewModifier {
    let focus: SplitFocusTransfer
    let isCompact: Bool
    let selection: SplitPane
    func apply(node: Node) {
        let previous = node.layoutDidUpdate
        // Install once; subsequent recompositions refresh the node-owned inputs
        // without accumulating callbacks or retaining obsolete selections.
        node.attachments[Self.key] = Handoff(focus: focus, isCompact: isCompact, selection: selection)
        guard node.attachments[Self.installedKey] == nil else { return }
        node.attachments[Self.installedKey] = true
        node.layoutDidUpdate = { node in
            previous?(node)
            (node.attachments[Self.key] as? Handoff)?.apply(node)
        }
    }
    private static var key: String { "GuavaUI.split.focusHandoff" }
    private static var installedKey: String { "GuavaUI.split.focusHandoff.installed" }

    private struct Handoff {
        let focus: SplitFocusTransfer
        let isCompact: Bool
        let selection: SplitPane
        func apply(_ node: Node) {
            guard let visible = focus.pendingVisibility else { return }
            func locate(_ candidate: Node, preferred: Bool) -> Node? {
                guard candidate.acceptsSubtreeInput else { return nil }
                if preferred, isCompact, candidate.accessibility?.role == .tab,
                    candidate.accessibility?.state.isSelected == true
                {
                    return candidate
                }
                if preferred, !isCompact,
                    candidate.attachments[SplitContainerMarker.paneKey] as? SplitPane == selection
                {
                    return locate(candidate, preferred: false)
                }
                if !preferred, candidate.isFocusable && candidate.isTabStop { return candidate }
                return candidate.children.lazy.compactMap { locate($0, preferred: preferred) }.first
            }
            focus.pendingVisibility = nil
            if let target = locate(node, preferred: true) ?? locate(node, preferred: false) {
                FocusChainHolder.current?.focus(target, visible: visible)
                ScrollReveal.reveal(target)
            }
        }
    }
}

private func contains(_ candidate: Node, in ancestor: Node) -> Bool {
    var current: Node? = candidate
    while let node = current {
        if node === ancestor { return true }
        current = node.parent
    }
    return false
}
