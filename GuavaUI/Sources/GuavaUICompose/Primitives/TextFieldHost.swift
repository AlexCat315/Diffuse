import GuavaUIRuntime

struct _TextFieldInteractionState: Equatable {
    var isFocused: Bool = false
    var isComposing: Bool = false

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
        let configuration = TextFieldStyleConfiguration(
            content: AnyView(_TextFieldSurface(textField: textField,
                                               interactionState: interactionState,
                                               onFocusChange: onFocusChange,
                                               onEditingChange: onEditingChange)),
            placeholder: textField.placeholder,
            isFocused: interactionState.isFocused && !textField.disabled,
            isEditing: interactionState.isEditing && !textField.disabled,
            isError: false,
            isEnabled: !textField.disabled,
            theme: node.theme
        )
        return [style.makeBody(configuration)]
    }
}

struct _TextFieldSurface: _PrimitiveView {
    let textField: TextField
    let interactionState: _TextFieldInteractionState
    let onFocusChange: (Bool) -> Void
    let onEditingChange: (Bool) -> Void

    func _makeNode() -> Node {
        textField._makeNode()
    }

    func _updateNode(_ node: Node) {
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
    }
}