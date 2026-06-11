import GuavaUICompose
import GuavaUIRuntime

/// Invisible full-window modal barrier: swallows pointer / wheel / hover so
/// everything behind stays inert (no visual dimming, per design preference),
/// and centers its content. Lives in the portal layer, which is absolutely
/// positioned over the whole window.
struct ModalBarrier<Content: View>: _PrimitiveView {
    let onBackgroundTap: (() -> Void)?
    let content: Content

    init(onBackgroundTap: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.onBackgroundTap = onBackgroundTap
        self.content = content()
    }

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = true
        node.isFocusable = false
        return node
    }

    func _updateNode(_ node: Node) {
        clearOutsideFocus(node)
        guard let registry = InteractionRegistryHolder.current else { return }
        let onBackgroundTap = onBackgroundTap
        let route = InputHandlerRoute(role: .control,
                                      priority: .modal,
                                      debugName: "modal.barrier")
        registry.setPointer(node, route: route) { _, pointerPhase, eventPhase in
            guard eventPhase == .target else { return .ignored }
            if pointerPhase == .down { onBackgroundTap?() }
            return .handled
        }
        registry.setMotion(node, route: route) { _, phase in
            phase == .target ? .handled : .ignored
        }
        registry.setWheel(node, route: route) { _, phase in
            phase == .target ? .handled : .ignored
        }
    }

    /// A control behind the barrier holding focus (viewport, text field)
    /// would keep winning key delivery over the modal's shortcuts; drop
    /// focus unless it belongs to the barrier's own subtree.
    private func clearOutsideFocus(_ node: Node) {
        guard let chain = FocusChainHolder.current,
              let focused = chain.focused else { return }
        var cursor: Node? = focused
        while let current = cursor {
            if current === node { return }
            cursor = current.parent
        }
        chain.clear()
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.positionType = .absolute
        layout.setPosition(0, edge: .left)
        layout.setPosition(0, edge: .top)
        layout.setPosition(0, edge: .right)
        layout.setPosition(0, edge: .bottom)
        layout.flexDirection = .column
        layout.alignItems = .center
        layout.justifyContent = .center
        return layout
    }

    var _children: [any View] { [content] }
}
