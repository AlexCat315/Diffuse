internal import GuavaUIRuntime

/// A dedicated lane keeps resizing out of the editable text's hit region.
struct EditorHeightHandle: _PrimitiveView {
    let value: Binding<Float>
    let limits: EditorHeightLimits
    let label: String
    let isEnabled: Bool
    let extent: Float
    private static let startKey = "editor.resize.start"
    private static let basisKey = "editor.resize.basis"
    private static let hoverKey = "editor.resize.hover"
    private static let revealKey = "editor.resize.reveal"
    private struct Start { let y: Float; let height: Float }
    private struct Basis: Equatable { let limits: EditorHeightLimits; let extent: Float }

    func _makeNode() -> Node {
        let node = Node(); node.addResource(EditorHeightHandleLifetime()); return node
    }
    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateLayout(_ layout: LayoutNode) { layout.height = extent; layout.flexShrink = 0 }
    func _updateNode(_ node: Node) {
        let chain = FocusChainHolder.current, capture = PointerCaptureHolder.current
        let basis = Basis(limits: limits, extent: extent)
        if node.attachments[Self.basisKey] as? Basis != basis { release(node) }
        node.attachments[Self.basisKey] = basis
        node.isHitTestable = isEnabled; node.isFocusable = isEnabled
        node.cursor = isEnabled ? .resizeVertical : .notAllowed
        node.accessibility = AccessibilitySemantics(.slider) {
            $0.label = label; $0.value = String(limits.clamp(value.wrappedValue))
            $0.state.isEnabled = isEnabled
        }
        node.accessibilityActions = AccessibilityActions()
        node.layoutDidUpdate = { node in
            if node.attachments.removeValue(forKey: Self.revealKey) as? Bool == true { ScrollReveal.reveal(node) }
        }
        node.attachments[PointerCaptureAttachmentKey.didLoseCapture] = { [weak node] in
            node?.attachments.removeValue(forKey: Self.startKey); node?.markRenderDirty()
        }
        node.attachments[TextInputAttachmentKey.focusChangeHandler] = { [weak node] (_: Bool) in node?.markRenderDirty() }
        node.draw = { [weak node, weak chain] list, origin in
            guard let node else { return }
            let focused = chain?.focused === node && chain?.isFocusVisible == true
            let hot = isEnabled && (node.attachments[Self.hoverKey] as? Bool == true || node.attachments[Self.startKey] != nil)
            let frame = UIRect(x: Float(origin.x), y: Float(origin.y), width: Float(node.frame.width), height: Float(node.frame.height))
            if hot { list.addRoundedRect(frame, radius: 4, color: node.theme.colors.stateLayerHover.multipliedAlpha(node.opacity)) }
            if focused {
                list.addRoundedRectStroke(.init(x: frame.x + 2, y: frame.y + 2, width: max(0, frame.width - 4), height: max(0, frame.height - 4)),
                                          radius: 4, width: 1, color: node.theme.colors.focusRing.multipliedAlpha(node.opacity))
            }
            list.addRoundedRect(.init(x: frame.x + max(0, (frame.width - 28) / 2), y: frame.y + (frame.height - 2) / 2,
                                      width: min(28, frame.width), height: 2), radius: 1,
                                color: (focused || hot ? node.theme.colors.accent : node.theme.colors.onSurfaceMuted)
                                    .multipliedAlpha(node.opacity * (isEnabled ? 0.55 : 0.25)))
        }
        guard isEnabled else {
            release(node); if chain?.focused === node { chain?.clear() }
            node.attachments.removeValue(forKey: Self.hoverKey)
            InteractionRegistryHolder.current?.remove(node); return
        }
        node.accessibilityActions.increment = { [weak node] in if let node { write(value.wrappedValue + 16, node) } }
        node.accessibilityActions.decrement = { [weak node] in if let node { write(value.wrappedValue - 16, node) } }
        node.accessibilityActions.setValue = { [weak node] text in if let node, let next = Float(text), next.isFinite { write(next, node) } }
        guard let registry = InteractionRegistryHolder.current else { return }
        registry.setHover(node) { [weak node] event in
            guard let node else { return }
            node.attachments[Self.hoverKey] = node.supportsControlHover && event == .enter; node.markRenderDirty()
        }
        registry.setPointer(node) { [weak node] event, phase, eventPhase in
            guard let node, eventPhase == .target, event.button == .left, node.acceptsSubtreeInput else { return .ignored }
            if phase == .down {
                chain?.focus(node, visible: false)
                node.attachments[Self.startKey] = Start(y: event.y, height: limits.clamp(value.wrappedValue)); capture?.acquire(node)
            } else { release(node) }
            node.markRenderDirty(); return .handled
        }
        registry.setMotion(node) { [weak node] event, phase in
            guard let node, phase == .target, capture?.target === node,
                  let start = node.attachments[Self.startKey] as? Start else { return .ignored }
            write(start.height + event.y - start.y, node, reveal: false); return .handled
        }
        registry.setKey(node) { [weak node] event, phase in
            guard let node, phase == .target, event.modifiers.isDisjoint(with: [.ctrl, .gui, .alt]) else { return .ignored }
            let step: Float = event.modifiers.contains(.shift) ? 64 : 16
            switch event.scancode {
            case Scancode.arrowUp: write(value.wrappedValue - step, node)
            case Scancode.arrowDown: write(value.wrappedValue + step, node)
            case Scancode.pageUp: write(value.wrappedValue - 64, node)
            case Scancode.pageDown: write(value.wrappedValue + 64, node)
            case Scancode.home: write(limits.minimum, node)
            case Scancode.end: write(limits.maximum, node)
            case Scancode.escape:
                guard let start = node.attachments[Self.startKey] as? Start else { return .ignored }
                write(start.height, node); release(node)
            default: return .ignored
            }
            chain?.focus(node, visible: true)
            return .handled
        }
    }
    private func write(_ proposed: Float, _ node: Node, reveal: Bool = true) {
        guard isEnabled, node.acceptsSubtreeInput, node.accessibility?.state.isEnabled == true,
              node.firstResource(EditorHeightHandleLifetime.self)?.isMounted == true, proposed.isFinite else { return }
        let next = limits.clamp(proposed)
        if value.wrappedValue != next {
            if reveal { node.attachments[Self.revealKey] = true }
            value.wrappedValue = next
        }
    }
    private func release(_ node: Node) {
        node.attachments.removeValue(forKey: Self.startKey)
        node.attachments.removeValue(forKey: Self.revealKey)
        if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
        node.markRenderDirty()
    }
    var _children: [any View] { [] }
}

private final class EditorHeightHandleLifetime: NodeResource {
    private(set) var isMounted = false
    private weak var capture: PointerCapture?
    private weak var chain: FocusChain?
    func mount(node: Node) { isMounted = true; capture = PointerCaptureHolder.current; chain = FocusChainHolder.current }
    func unmount(node: Node) {
        isMounted = false
        if capture?.target === node { capture?.release() }
        if chain?.focused === node { chain?.clear() }
    }
}
