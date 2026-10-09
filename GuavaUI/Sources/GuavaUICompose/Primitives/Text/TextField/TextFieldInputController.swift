#if canImport(CoreGraphics)
import CoreGraphics
#endif
import GuavaUIRuntime

extension TextField {
    struct InputController {
        let textField: TextField
        let state: FieldState

        private func notifyEditingChange(on node: Node) {
            guard let handler = node.attachments[TextInputAttachmentKey.editingChangeHandler]
                    as? TextInputEditingChangeHandler else { return }
            handler(state.composition.isActive)
        }

        func install(on node: Node, registry: InteractionRegistry) {
            registry.setEditing(node, route: .textInput) { event, _ in
                guard !textField.behavior.readOnly else { return .handled }
                state.composition.text = event.text
                let compositionCount = event.text.count
                state.composition.start = clamp(Int(event.start), 0, compositionCount)
                state.composition.length = clamp(Int(event.length),
                                                0,
                                                max(0, compositionCount - state.composition.start))
                notifyEditingChange(on: node)
                textField.recordCaretActivity(state)
                return .handled
            }
            registry.setText(node, route: .textInput) { incoming, _ in
                guard !textField.behavior.readOnly else { return .handled }
                textField.insertReplacingSelection(incoming, state: state)
                notifyEditingChange(on: node)
                return .handled
            }
            registry.setKey(node, route: .textInput) { event, _ in
                textField.handleKey(event, state: state, node: node) ? .handled : .ignored
            }
            registry.setPointer(node, route: .textInput) { event, phase, _ in
                guard event.button == .left else { return .ignored }
                switch phase {
                case .down:
                    state.transaction.history.breakGroup()
                    if textField.behavior.clearable,
                       let hitX = state.pointer.clearHitX,
                       Float(event.x) >= hitX {
                        textField.performClear(state: state)
                        notifyEditingChange(on: node)
                        return .handled
                    }
                    textField.handlePointerDown(event: event, state: state, node: node)
                    return .handled
                case .up:
                    state.pointer.isDragging = false
                    if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
                    return .handled
                }
            }
            registry.setMotion(node, route: .textInput) { event, _ in
                let point = CGPoint(x: CGFloat(event.x), y: CGFloat(event.y))
                if state.pointer.isDragging {
                    let target = textField.characterIndex(atWindowPoint: point,
                                                          state: state,
                                                          node: node)
                    if state.selection.anchor == nil {
                        state.selection.anchor = state.selection.cursorIndex
                    }
                    state.selection.cursorIndex = target
                    textField.recordCaretActivity(state)
                    return .handled
                }
                // Without a subscriber this stays free — resolving the pointer
                // to a character index costs a layout pass, which pointer motion
                // would otherwise charge to every frame.
                guard textField.events.onHoverChange != nil,
                      TextEnvironmentHolder.current != nil else { return .ignored }
                let target = textField.characterIndex(atWindowPoint: point,
                                                     state: state,
                                                     node: node)
                textField.reportHover(TextFieldHoverAnchor(characterIndex: target,
                                                           windowX: event.x,
                                                           windowY: event.y))
                return .ignored
            }
            registry.setHover(node) { phase in
                let onHover = node.attachments["__textfield_chrome_hover"] as? (Bool) -> Void
                onHover?(phase == .enter)
                switch phase {
                case .enter:
                    node.attachments[TextField.scrollbarHoveredKey] = true
                    textField.setScrollbarChromeVisible(true, on: node)
                case .leave:
                    node.attachments[TextField.scrollbarHoveredKey] = false
                    textField.setScrollbarChromeVisible(false, on: node)
                    textField.reportHover(nil)
                }
            }
            registry.setWheel(node, route: .textInput) { event, _ in
                textField.refreshScrollableMetrics(state: state, node: node)
                let previousOffset = state.scroll.offsetY
                let previousX = state.scroll.horizontal.offset
                let nextOffset = clamp(state.scroll.offsetY - event.y * TextField.multilineWheelStep,
                                       0,
                                       state.scroll.maxY)
                state.scroll.offsetY = nextOffset
                let wheelX = event.x == 0 && textField.layout.axis == .horizontal ? event.y : event.x
                state.scroll.horizontal.offset = clamp(previousX - wheelX * TextField.multilineWheelStep,
                    0, state.scroll.horizontal.maximum)
                state.scroll.needsCaretReveal = false
                node.contentOffset = CGPoint(x: CGFloat(state.scroll.horizontal.offset), y: CGFloat(nextOffset))
                if nextOffset != previousOffset || state.scroll.horizontal.offset != previousX {
                    node.firstResource(TextCompletionSession.self)?.dismiss()
                    textField.reportHover(nil)
                }
                return ScrollConsumePolicy.whenOffsetChanged
                    .result(didScroll: nextOffset != previousOffset || state.scroll.horizontal.offset != previousX)
            }
        }
    }

    func updateInteractionHandlers(for node: Node, state: FieldState) {
        if behavior.disabled {
            // Ensure no stale handlers keep firing when an input flips
            // disabled mid-frame.
            InteractionRegistryHolder.current?.remove(node)
            state.pointer.isDragging = false
            if PointerCaptureHolder.current?.target === node { PointerCaptureHolder.current?.release() }
            if FocusChainHolder.current?.focused === node { FocusChainHolder.current?.clear() }
            return
        }
        guard let registry = InteractionRegistryHolder.current else { return }
        InputController(textField: self, state: state).install(on: node, registry: registry)
    }
}
