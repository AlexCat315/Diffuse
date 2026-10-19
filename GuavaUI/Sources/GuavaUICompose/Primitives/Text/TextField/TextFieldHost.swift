import GuavaUIRuntime

struct _TextFieldInteractionState: Equatable {
    var isFocused: Bool = false
    var isComposing: Bool = false
    var isHovered: Bool = false

    var isEditing: Bool {
        isFocused || isComposing
    }
}

struct _StatefulTextField: View {
    let textField: TextField

    @State var interactionState = _TextFieldInteractionState()
    @State private var gutterSession = TextGutterSession()

    var body: some View {
        _TextFieldStyleHost(textField: textField,
                            gutterSession: gutterSession,
                            interactionState: interactionState,
                            onHoverChange: { hovered in
                                if interactionState.isHovered != hovered { interactionState.isHovered = hovered }
                            },
                            onFocusChange: { focused in
                                if interactionState.isFocused != focused {
                                    interactionState.isFocused = focused
                                }
                                if !focused, interactionState.isComposing {
                                    interactionState.isComposing = false
                                }
                            },
                            onEditingChange: { isComposing in
                                if interactionState.isComposing != isComposing {
                                    interactionState.isComposing = isComposing
                                }
                            })
    }
}

struct _TextFieldStyleHost: _PrimitiveView {
    let textField: TextField
    let gutterSession: TextGutterSession
    let interactionState: _TextFieldInteractionState
    let onHoverChange: (Bool) -> Void
    let onFocusChange: (Bool) -> Void
    let onEditingChange: (Bool) -> Void

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.isFocusable = false
        return node
    }

    func _updateNode(_ node: Node) {
        node.isHitTestable = false
        node.isFocusable = false
        node.applyTouchControlExtent()
        if !node.supportsControlHover { onHoverChange(false) }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        layout.flexDirection = .column
        layout.alignItems = .stretch
        return layout
    }

    func _children(for node: Node) -> [any View] {
        let style = node.compositionValue(of: TextFieldStyleEnvironment.key)
        var resolvedField = textField
        if resolvedField.decoration.size == .automatic {
            resolvedField.decoration.size = node.compositionValue(of: ControlSizeEnvironment.key).textFieldSize
        }
        let surface = _TextFieldSurface(textField: resolvedField,
                                               gutterSession: gutterSession,
                                               interactionState: interactionState,
                                               onHoverChange: onHoverChange,
                                               onFocusChange: onFocusChange,
                                               onEditingChange: onEditingChange)
        // Single-line controls retain their small leaf hierarchy. Multiline
        // editors keep a stable container when code presentation is toggled.
        let content = resolvedField.layout.axis == .vertical
            ? AnyView(TextFieldContent(surface: surface, gutterSession: gutterSession)) : AnyView(surface)
        let configuration = TextFieldStyleConfiguration(
            content: content,
            placeholder: textField.placeholder,
            isFocused: interactionState.isFocused && !textField.behavior.disabled,
            isEditing: interactionState.isEditing && !textField.behavior.disabled,
            isError: false,
            isEnabled: !textField.behavior.disabled,
            theme: node.theme,
            isHovered: interactionState.isHovered && node.supportsControlHover && !textField.behavior.disabled
        )
        return [style.makeBody(configuration)]
    }
}

/// Keep the measured leaf and positioned controls as siblings: Yoga measured
/// nodes cannot own children, and custom overlay measurement must not shrink
/// an explicitly sized editor down to the text's intrinsic width.
private struct TextFieldContent: _PrimitiveView {
    let surface: _TextFieldSurface
    let gutterSession: TextGutterSession
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _updateNode(_ node: Node) {}
    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode(); layout.flexDirection = .column; layout.alignItems = .stretch
        layout.flexGrow = 1; layout.flexShrink = 1; layout.minWidth = 0; layout.minHeight = 0
        return layout
    }
    var _children: [any View] {
        [surface, TextGutterControls(gutterSession).absolutePosition(left: 0, top: 0, right: 0, bottom: 0)]
    }
}

struct _TextFieldSurface: _PrimitiveView {
    let textField: TextField
    let gutterSession: TextGutterSession
    let interactionState: _TextFieldInteractionState
    let onHoverChange: (Bool) -> Void
    let onFocusChange: (Bool) -> Void
    let onEditingChange: (Bool) -> Void

    func _makeNode() -> Node {
        let node = textField._makeNode(); node.addResource(gutterSession); return node
    }

    func _updateNode(_ node: Node) {
        node.attachments["__textfield_chrome_hover"] = onHoverChange
        node.applyTouchControlExtent()
        let supportsHover = node.supportsControlHover
        if !supportsHover {
            node.attachments[TextField.scrollbarHoveredKey] = false
            if node.attachments["__textfield_pointer_hover_supported"] as? Bool == true {
                textField.setScrollbarChromeVisible(false, on: node)
                textField.reportHover(nil)
            }
        }
        node.attachments["__textfield_pointer_hover_supported"] = supportsHover
        textField.updateSurfaceNode(node,
                                    interactionState: interactionState,
                                    onFocusChange: onFocusChange,
                                    onEditingChange: onEditingChange)
    }

    func _makeLayoutNode() -> LayoutNode? {
        textField._makeLayoutNode()
    }

    func _updateLayout(_ layout: LayoutNode) {
        textField._updateLayout(layout)
        // The editable surface fills explicit field chrome, including numeric
        // axis cells, while retaining its intrinsic size when unconstrained.
        layout.flexGrow = 1
        layout.flexShrink = 1
    }
}
