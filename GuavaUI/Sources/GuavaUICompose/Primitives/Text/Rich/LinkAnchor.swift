import GuavaUIRuntime

/// The keyboard and accessibility face of one link in a paragraph. It sits
/// over the link's first line fragment, takes Tab focus, announces itself as
/// a link with its full text and destination, and opens on Return. Pointer
/// input passes through to the paragraph, which hit-tests every fragment.
struct RichTextLinkAnchor: _PrimitiveView {
    let source: RichTextStyleSource
    let index: Int
    let onOpenLink: ((String) -> Void)?

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.isFocusable = true
        return node
    }

    func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    func _updateLayout(_ layout: LayoutNode) {
        layout.setWidthPercent(100)
        layout.setHeightPercent(100)
    }

    func _updateNode(_ node: Node) {
        let destination = source.destinations[index]
        let open = onOpenLink.map { handler in { handler(destination) } }
        node.isFocusable = open != nil
        node.accessibility = AccessibilitySemantics(.link) {
            $0.label = source.linkText(index)
            $0.help = destination
            $0.state.isEnabled = open != nil
        }
        node.accessibilityActions = AccessibilityActions()
        node.accessibilityActions.activate = open
        let source = source, index = index
        node.attachments[TextInputAttachmentKey.focusChangeHandler] = { (focused: Bool) in
            guard let surface = source.node else { return }
            let current = surface.attachments[RichTextSurface.focusedLinkKey] as? Int
            if focused { surface.attachments[RichTextSurface.focusedLinkKey] = index }
            else if current == index { surface.attachments.removeValue(forKey: RichTextSurface.focusedLinkKey) }
            surface.markRenderDirty(reason: .focusChange)
        } as TextInputFocusChangeHandler
        guard let registry = InteractionRegistryHolder.current else { return }
        guard let open else { registry.remove(node); return }
        registry.setKey(node) { event, phase in
            guard phase != .capture, !event.isRepeat else { return .ignored }
            switch event.scancode {
            case Scancode.return, Scancode.keypadEnter: open(); return .handled
            default: return .ignored
            }
        }
    }
}
