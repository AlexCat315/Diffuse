import CoreGraphics
import GuavaUIRuntime

extension TextField {
    struct InputController {
        let textField: TextField
        let state: FieldState

        private func notifyEditingChange(on node: Node) {
            guard let handler = node.attachments[TextInputAttachmentKey.editingChangeHandler]
                    as? TextInputEditingChangeHandler else { return }
            handler(state.isComposing)
        }

        func install(on node: Node, registry: InteractionRegistry) {
            registry.setEditing(node, route: .textInput) { event, _ in
                guard !textField.readOnly else { return .handled }
                state.compositionText = event.text
                let compositionCount = event.text.count
                state.compositionStart = clamp(Int(event.start), 0, compositionCount)
                state.compositionLength = clamp(Int(event.length),
                                                0,
                                                max(0, compositionCount - state.compositionStart))
                notifyEditingChange(on: node)
                textField.recordCaretActivity(state)
                return .handled
            }
            registry.setText(node, route: .textInput) { incoming, _ in
                guard !textField.readOnly else { return .handled }
                textField.insertReplacingSelection(incoming, state: state)
                notifyEditingChange(on: node)
                return .handled
            }
            registry.setKey(node, route: .textInput) { event, _ in
                textField.handleKey(event, state: state, node: node) ? .handled : .ignored
            }
            registry.setPointer(node, route: .textInput) { event, phase, _ in
                switch phase {
                case .down:
                    if textField.clearable,
                       let hitX = state.clearHitX,
                       Float(event.x) >= hitX {
                        textField.performClear(state: state)
                        notifyEditingChange(on: node)
                        return .handled
                    }
                    textField.handlePointerDown(event: event, state: state, node: node)
                    return .handled
                case .up:
                    state.isDragging = false
                    PointerCaptureHolder.current?.release()
                    return .handled
                }
            }
            registry.setMotion(node, route: .textInput) { event, _ in
                guard state.isDragging else { return .ignored }
                let target = textField.characterIndex(atWindowPoint: CGPoint(x: CGFloat(event.x),
                                                                             y: CGFloat(event.y)),
                                                      state: state,
                                                      node: node)
                if state.selectionAnchor == nil {
                    state.selectionAnchor = state.cursorIndex
                }
                state.cursorIndex = target
                return .handled
            }
            registry.setHover(node) { phase in
                switch phase {
                case .enter:
                    node.attachments[TextField.scrollbarHoveredKey] = true
                    textField.setScrollbarChromeVisible(true, on: node)
                case .leave:
                    node.attachments[TextField.scrollbarHoveredKey] = false
                    textField.setScrollbarChromeVisible(false, on: node)
                }
            }
            registry.setWheel(node, route: .textInput) { event, _ in
                textField.refreshScrollableMetrics(state: state, node: node)
                guard state.maxScrollY > 0 else { return .ignored }
                let previousOffset = state.scrollOffsetY
                let nextOffset = clamp(state.scrollOffsetY - event.y * TextField.multilineWheelStep,
                                       0,
                                       state.maxScrollY)
                state.scrollOffsetY = nextOffset
                node.contentOffset = CGPoint(x: 0, y: CGFloat(nextOffset))
                return ScrollConsumePolicy.whenOffsetChanged
                    .result(didScroll: nextOffset != previousOffset)
            }
        }
    }

    func updateInteractionHandlers(for node: Node, state: FieldState) {
        if disabled {
            // Ensure no stale handlers keep firing when an input flips
            // disabled mid-frame.
            InteractionRegistryHolder.current?.remove(node)
            return
        }
        guard let registry = InteractionRegistryHolder.current else { return }
        InputController(textField: self, state: state).install(on: node, registry: registry)
    }
}
