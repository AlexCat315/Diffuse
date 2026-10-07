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

    var body: some View {
        _TextFieldStyleHost(textField: textField,
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
        if resolvedField.size == .automatic {
            resolvedField.size = node.compositionValue(of: ControlSizeEnvironment.key).textFieldSize
        }
        let configuration = TextFieldStyleConfiguration(
            content: AnyView(_TextFieldSurface(textField: resolvedField,
                                               interactionState: interactionState,
                                               onHoverChange: onHoverChange,
                                               onFocusChange: onFocusChange,
                                               onEditingChange: onEditingChange)),
            placeholder: textField.placeholder,
            isFocused: interactionState.isFocused && !textField.disabled,
            isEditing: interactionState.isEditing && !textField.disabled,
            isError: false,
            isEnabled: !textField.disabled,
            theme: node.theme,
            isHovered: interactionState.isHovered && !textField.disabled
        )
        return [style.makeBody(configuration)]
    }
}

struct _TextFieldSurface: _PrimitiveView {
    let textField: TextField
    let interactionState: _TextFieldInteractionState
    let onHoverChange: (Bool) -> Void
    let onFocusChange: (Bool) -> Void
    let onEditingChange: (Bool) -> Void

    func _makeNode() -> Node {
        textField._makeNode()
    }

    func _updateNode(_ node: Node) {
        node.attachments["__textfield_chrome_hover"] = onHoverChange
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
        // Multiline fields fill an allocated editor/JSON viewport while
        // retaining their intrinsic height when unconstrained.
        if textField.axis == .vertical {
            layout.flexGrow = 1
            layout.flexShrink = 1
        }
    }
}
