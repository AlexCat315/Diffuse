#if canImport(CoreGraphics)
import CoreGraphics
#endif
import EngineKernel
import GuavaUIRuntime

/// Text input field. The default horizontal axis is single-line; the
/// vertical axis accepts explicit newline insertion and grows in height to fit
/// those lines.
///
/// Editing state survives recomposition in the host node.
///
/// Configure meaningful groups, for example:
/// `TextField("Password", text: $password) { $0.behavior.secure = true }`
///
/// - Reads from `TextEnvironment` for shaping; without one installed the
///   field still accepts input but renders no glyphs.
public struct TextField: View {

    public enum Axis: Sendable, Equatable {
        case horizontal
        case vertical
    }

    /// Visual size variants matching Element Plus Input semantics.
    /// Drives field height, horizontal padding, and font metrics.
    public enum Size: Sendable, Equatable {
        case automatic
        case large
        case regular
        case small
    }

    public let text: Binding<TextBuffer>
    public let placeholder: String
    public var layout = TextFieldLayout()
    public var behavior = TextFieldBehavior()
    public var decoration = TextFieldDecoration()
    public var codeEditing = TextFieldCodeEditing()
    public var navigation = TextFieldNavigation()
    public var events = TextFieldEvents()

    public init(_ placeholder: String = "",
                text: Binding<TextBuffer>,
                configure: (inout TextField) -> Void = { _ in }) {
        self.text = text
        self.placeholder = placeholder
        configure(&self)
        layout.validate()
        behavior.validate()
        codeEditing.validate()
    }

    public var body: some View {
        _StatefulTextField(textField: self)
    }

    private struct MeasureInputs: Equatable {
        let text: TextBuffer
        let placeholder: String
        let axis: Axis
        let wrapsLines: Bool
        let maxVisibleLines: Int
        let showsLineNumbers: Bool
        let secure: Bool
    }

    private struct CodePaintIdentity: Equatable {
        let diagnostics: TextDiagnostics
        let showsLineNumbers: Bool
        let lineNumberColor: Color?
        let lineNumberGutterColor: Color?
        let syntaxColoringEnabled: Bool
        let syntaxRevision: AnyHashable?
        init(_ code: TextFieldCodeEditing) {
            diagnostics = code.diagnostics
            showsLineNumbers = code.showsLineNumbers
            lineNumberColor = code.lineNumberColor
            lineNumberGutterColor = code.lineNumberGutterColor
            syntaxColoringEnabled = code.syntaxColorAtUTF8Offset != nil
            syntaxRevision = code.syntaxRevision
        }
    }

    private struct PaintIdentity: Equatable {
        let text: TextBuffer
        let placeholder: String
        let layout: TextFieldLayout
        let behavior: TextFieldBehavior
        let decoration: TextFieldDecoration
        let code: CodePaintIdentity
        let isFocused: Bool
    }

    private static let minimumFieldHeightDefault: Float = 32
    static let multilineWheelStep: Float = 30
    static let scrollbarTrackThickness: Float = 6
    static let scrollbarInset: Float = 3
    private var minimumFieldHeight: Float {
        switch decoration.size {
        case .large:   return 40
        case .automatic, .regular: return 32
        case .small:   return 24
        }
    }
    /// Optional intrinsic font size override applied per `Size` so an
    /// unstyled TextField still picks up a smaller body in the `.small`
    /// variant. Returning `nil` keeps the active TextEnvironment default.
    private var sizeFontSize: Float? {
        switch decoration.size {
        case .large:   return 14
        case .automatic, .regular: return 14
        case .small:   return 12
        }
    }
    private static let caretBlinkHalfPeriod: Double = 0.5
    private static let caretBlinkSteadyDuration: Double = 0.5
    private static let measureInputsKey = "__textfield_measure_inputs"
    static let scrollbarHoveredKey = "__textfield_scrollbar_hovered"
    static let scrollbarChromeOpacityKey = "__textfield_scrollbar_chrome_opacity"
    static let surfaceMarkerKey = "__textfield_surface"
    private static let focusRequestIDKey = "__textfield_focus_request_id"
    func layoutEngine(for node: Node? = nil) -> LayoutEngine {
        LayoutEngine(textField: self, letterSpacing: node?.textStyleValue(StyleAttachmentKey.letterSpacing) ?? 0)
    }

    func _makeNode() -> Node {
        let n = Node()
        n.addResource(TextCompletionSession())
        n.isHitTestable = true
        n.isFocusable = true
        n.clipsToBounds = true
        return n
    }

    func _updateNode(_ node: Node) {
        updateSurfaceNode(node,
                          interactionState: _TextFieldInteractionState(),
                          onFocusChange: { _ in },
                          onEditingChange: { _ in })
    }

    func updateSurfaceNode(_ node: Node,
                           interactionState: _TextFieldInteractionState,
                           onFocusChange: @escaping (Bool) -> Void,
                           onEditingChange: @escaping (Bool) -> Void) {
        node.accessibility = AccessibilitySemantics(.textField) {
            $0.label = placeholder
            $0.state.isEnabled = !behavior.disabled; $0.state.isReadOnly = behavior.readOnly
            $0.state.isSecure = behavior.secure
        }
        updateAccessibilityValue(on: node, buffer: text.wrappedValue)
        node.accessibilityActions = AccessibilityActions()
        if !behavior.disabled {
            node.accessibilityActions.activate = { [weak node] in
                if let node { FocusChainHolder.current?.focus(node, visible: true) }
            }
        }
        if !behavior.disabled && !behavior.readOnly {
            node.accessibilityActions.setValue = { value in
                let next = behavior.maxLength.map { String(value.prefix($0)) } ?? value
                let buffer = TextBuffer(next)
                text.wrappedValue = buffer; events.onChange?(buffer)
            }
        }

        node.attachments[Self.surfaceMarkerKey] = true
        // The owning style controls chrome. Resetting it here makes every
        // hover/focus recompose restart an interpolation from transparent.
        node.cursor = behavior.disabled ? .arrow : .ibeam
        node.isFocusable = !behavior.disabled
        node.isHitTestable = !behavior.disabled
        node.clipsToBounds = true
        if node.attachments[Self.scrollbarHoveredKey] == nil {
            node.attachments[Self.scrollbarHoveredKey] = false
        }
        if node.attachments[Self.scrollbarChromeOpacityKey] == nil {
            node.attachments[Self.scrollbarChromeOpacityKey] = Float(0)
        }

        // Reuse FieldState if this node is being recycled by reconcile;
        // otherwise create one and seed cursor at the end of the current text.
        let state: FieldState
        if let existing = node.attachments["__textfield_state"] as? FieldState {
            state = existing
        } else {
            state = FieldState()
            state.selection.cursorIndex = text.wrappedValue.characterCount
            node.attachments["__textfield_state"] = state
        }
        state.hostNode = node
        node.firstResource(TextCompletionSession.self)?.configure(field: self, state: state)
        if let editHistory = codeEditing.editHistory { state.transaction.history = editHistory }
        normalizeIndices(state)
        state.transaction.history.synchronize(text.wrappedValue)
        if !behavior.readOnly && !behavior.disabled {
            node.attachments[TextEditingCommands.undoKey] = { restoreHistory(state, redo: false) }
            node.attachments[TextEditingCommands.redoKey] = { restoreHistory(state, redo: true) }
            node.attachments[TextEditingCommands.canUndoKey] = { state.transaction.history.canUndo }
            node.attachments[TextEditingCommands.canRedoKey] = { state.transaction.history.canRedo }
        } else {
            for key in [TextEditingCommands.undoKey, TextEditingCommands.redoKey, TextEditingCommands.canUndoKey, TextEditingCommands.canRedoKey] {
                node.attachments.removeValue(forKey: key)
            }
        }
        let snapshot = self
        let paintIdentity = PaintIdentity(text: text.wrappedValue,
                                          placeholder: placeholder,
                                          layout: layout,
                                          behavior: behavior,
                                          decoration: decoration,
                                          code: CodePaintIdentity(codeEditing),
                                          isFocused: interactionState.isFocused)

        updateInteractionHandlers(for: node, state: state)
        node.attachments[TextInputAttachmentKey.editActions] = TextEditActions(
            canPerform: { command in
                state.transaction.history.synchronize(snapshot.text.wrappedValue)
                guard !snapshot.behavior.disabled, !snapshot.behavior.readOnly else { return false }
                return command == .undo ? state.transaction.history.canUndo : state.transaction.history.canRedo
            },
            perform: { command in snapshot.restoreHistory(state, redo: command == .redo) }
        )
        node.attachments[WheelRoutingAttachmentKey.priority] = interactionState.isFocused
            ? WheelRoutingPriority.preferFocused
            : nil
        node.attachments[TextInputAttachmentKey.focusChangeHandler] = { [weak node] focused in
            state.transaction.history.breakGroup()
            node?.attachments[WheelRoutingAttachmentKey.priority] = focused
                ? WheelRoutingPriority.preferFocused
                : nil
            if !focused, state.composition.isActive {
                state.clearComposition()
                onEditingChange(false)
            }
            onFocusChange(focused)
            if focused {
                snapshot.recordCaretActivity(state)
                snapshot.events.onFocus?()
            } else {
                node?.firstResource(TextCompletionSession.self)?.dismiss()
                snapshot.events.onBlur?()
            }
        }
        node.attachments[TextInputAttachmentKey.editingChangeHandler] = { isComposing in
            onEditingChange(isComposing)
        }
        node.attachments[TextInputAttachmentKey.areaResolver] = { committedNode, absoluteOrigin in
            snapshot.committedTextInputArea(node: committedNode,
                                            state: state,
                                            absoluteOrigin: absoluteOrigin,
                                            isFocused: interactionState.isFocused)
        }

        if let focusRequestID = navigation.focusRequestID,
           node.attachments[Self.focusRequestIDKey] as? AnyHashable != focusRequestID {
            node.attachments[Self.focusRequestIDKey] = focusRequestID
            state.selection.anchor = 0
            state.selection.cursorIndex = text.wrappedValue.characterCount
            recordCaretActivity(state)
            FocusChainHolder.current?.focus(node)
        }

        if let caretRequestID = navigation.caretRequestID, let caretRequestIndex = navigation.caretRequestIndex,
           node.attachments["__textfield_caret_request_id"] as? AnyHashable != caretRequestID {
            node.attachments["__textfield_caret_request_id"] = caretRequestID
            state.selection.anchor = nil
            state.selection.cursorIndex = max(0, min(text.wrappedValue.characterCount, caretRequestIndex))
            recordCaretActivity(state)
            FocusChainHolder.current?.focus(node)
        }

        node.updateDraw(identity: paintIdentity) { list, origin in
            snapshot.render(node: node,
                            state: state,
                            list: list,
                            origin: origin,
                            interactionState: interactionState)
        }
        node.updateOverlayDraw(identity: paintIdentity) { [weak node] list, origin in
            guard let node else { return }
            let opacity = node.attachments[Self.scrollbarChromeOpacityKey] as? Float ?? 0
            guard opacity > 0.001 else { return }
            let engine = snapshot.layoutEngine(for: node)
            let bars = [engine.scrollbarMetrics(state: state, node: node, origin: origin),
                        engine.horizontalScrollbarMetrics(state: state, node: node, origin: origin)].compactMap { $0 }
            let colors = node.theme.colors
            for metrics in bars { list.addRoundedRect(metrics.trackRect,
                                radius: Self.scrollbarTrackThickness / 2,
                                color: colors.surfaceVariant.multipliedAlpha(node.opacity * opacity))
            list.addRoundedRect(metrics.thumbRect,
                                radius: Self.scrollbarTrackThickness / 2,
                                color: colors.onSurfaceMuted.multipliedAlpha(node.opacity * opacity)) }
        }
    }

    func updateAccessibilityValue(on node: Node, buffer: TextBuffer) {
        node.accessibilityValueProvider = AccessibilityValueProvider(revision: AnyHashable(buffer.identity)) {
            buffer.stringValue
        }
    }

    func setScrollbarChromeVisible(_ visible: Bool, on node: Node) {
        let current = node.attachments[Self.scrollbarChromeOpacityKey] as? Float ?? 0
        let target: Float = visible ? 1 : 0
        withAnimation(.semantic(.fast, in: node.theme)) {
            node.animatableSet(propertyKey: Self.scrollbarChromeOpacityKey,
                               current: current,
                               to: target) { [weak node] opacity in
                guard let node else { return }
                node.attachments[Self.scrollbarChromeOpacityKey] = opacity
                node.markRenderDirty(reason: .styleSet(field: "textFieldScrollbarChromeOpacity"))
            }
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        Self.installMeasureFunc(on: layout, snapshot: self)
        let inputs = MeasureInputs(text: text.wrappedValue,
                                   placeholder: placeholder,
                                   axis: self.layout.axis,
                                   wrapsLines: self.layout.wrapsLines,
                                   maxVisibleLines: self.layout.maxVisibleLines,
                                   showsLineNumbers: codeEditing.showsLineNumbers,
                                   secure: behavior.secure)
        layout.attachments[Self.measureInputsKey] = inputs
        if self.layout.axis == .vertical {
            layout.height = nil
            layout.minHeight = minimumFieldHeight
        } else {
            layout.minHeight = nil
            layout.height = resolvedFieldHeight(layout: layout)
        }
        return layout
    }

    func _updateLayout(_ layout: LayoutNode) {
        Self.installMeasureFunc(on: layout, snapshot: self)
        let next = MeasureInputs(text: text.wrappedValue,
                                 placeholder: placeholder,
                                 axis: self.layout.axis,
                                   wrapsLines: self.layout.wrapsLines,
                                 maxVisibleLines: self.layout.maxVisibleLines,
                                 showsLineNumbers: codeEditing.showsLineNumbers,
                                 secure: behavior.secure)
        let previous = layout.attachments[Self.measureInputsKey] as? MeasureInputs
        layout.attachments[Self.measureInputsKey] = next
        if self.layout.axis == .vertical {
            layout.height = nil
            layout.minHeight = minimumFieldHeight
        } else {
            layout.minHeight = nil
            layout.height = resolvedFieldHeight(layout: layout)
        }
        if self.layout.axis == .vertical {
            if previous != nil, previous != next {
                layout.markDirty()
            }
        }
    }

    // MARK: - Editing

    func handleKey(_ event: KeyEvent, state: FieldState, node: Node) -> Bool {
        // The bound text may have been rewritten since the last interaction;
        // re-anchor stale indices before any String.index arithmetic.
        normalizeIndices(state)
        if !behavior.readOnly, node.firstResource(TextCompletionSession.self)?.handleKey(event) == true { return true }
        if event.scancode == Scancode.f1, event.modifiers.isEmpty, let request = codeEditing.onRequestHover,
           let area = committedTextInputArea(node: node, state: state, absoluteOrigin: node.absoluteFrame.origin, isFocused: true) {
            request(TextFieldHoverAnchor(characterIndex: state.selection.cursorIndex, windowX: area.x, windowY: area.y + area.height))
            return true
        }
        if events.onKeyDown?(event) == true { return true }
        let mods = event.modifiers
        let shift = !mods.isDisjoint(with: .shift)
        let primaryModifier = !mods.isDisjoint(with: .gui) || !mods.isDisjoint(with: .ctrl)
        // macOS text-navigation idioms: Option = word-wise, Command = line-wise.
        // (Command+arrow reuses the Home/End paths since Mac keyboards have no
        // physical Home/End keys.)
        let option = !mods.isDisjoint(with: [.lalt, .ralt])
        let command = !mods.isDisjoint(with: .gui)
        let count = text.wrappedValue.characterCount
        // In read-only mode the field still accepts caret motion, selection,
        // and primary select/copy shortcuts so users can copy the value, but every mutation
        // (typing, paste, cut, backspace, delete, newline insert) is silently
        // dropped — matching Element Plus' readonly Input behaviour.
        let blockMutations = behavior.readOnly

        if primaryModifier, event.scancode == 29 || event.scancode == 28 {
            guard !blockMutations else { return true }
            restoreHistory(state, redo: event.scancode == 28 || shift)
            return true
        }
        let editKind: TextEditHistory.Kind = !primaryModifier && (event.scancode == Scancode.backspace || event.scancode == Scancode.delete) ? .deletion : .atomic
        beginEdit(state, kind: editKind)
        defer { endEdit(state) }
        if primaryModifier || [Scancode.arrowLeft, Scancode.arrowRight, Scancode.arrowUp, Scancode.arrowDown, Scancode.home, Scancode.end, Scancode.pageUp, Scancode.pageDown, Scancode.return, Scancode.tab].contains(event.scancode) { state.transaction.history.breakGroup() }

        // Primary shortcuts take priority over plain bindings.
        if primaryModifier {
            switch event.scancode {
            case Scancode.a:
                state.selection.anchor = 0
                state.selection.cursorIndex = count
                recordCaretActivity(state)
                return true
            case Scancode.c:
                if !behavior.secure, let r = selectionRange(state) {
                    ClipboardHolder.write?(substring(text.wrappedValue, r))
                }
                return true
            case Scancode.v:
                guard !blockMutations else { return true }
                if let s = ClipboardHolder.read?(), !s.isEmpty {
                    insertReplacingSelection(s, state: state)
                }
                return true
            case Scancode.x:
                guard !blockMutations else { return true }
                if let r = selectionRange(state) {
                    if !behavior.secure {
                        ClipboardHolder.write?(substring(text.wrappedValue, r))
                    }
                    deleteSelection(state: state)
                }
                return true
            default:
                break
            }
        }

        switch event.scancode {
        case 43: // USB HID Tab; code fields consume it before focus traversal.
            guard self.layout.axis == .vertical, let indentationWidth = codeEditing.indentationWidth, !primaryModifier else { return false }
            if !blockMutations { indentLines(width: indentationWidth, removing: shift, state: state) }
            return true
        case Scancode.escape:
            guard let onCancel = events.onCancel else { return false }
            onCancel()
            return true
        case Scancode.backspace:
            guard !blockMutations else { return true }
            if !deleteSelection(state: state) {
                guard state.selection.cursorIndex > 0 else { return true }
                // Option deletes to the previous word boundary, Command to the
                // start of the displayed row; plain Backspace removes one character.
                let deleteTo: Int = {
                    if command { return min(state.selection.cursorIndex - 1, lineBoundary(ending: false, state: state, node: node)) }
                    if option { return wordBoundaryBefore(in: text.wrappedValue,
                                                          offset: state.selection.cursorIndex) }
                    return state.selection.cursorIndex - 1
                }()
                let startByte = text.wrappedValue.utf8Offset(forCharacterIndex: deleteTo)
                let s = text.wrappedValue.delete(characterRange: deleteTo..<state.selection.cursorIndex)
                text.wrappedValue = s
                state.selection.cursorIndex = s.characterIndex(forUTF8Offset: startByte)
                recordCaretActivity(state)
                events.onChange?(s)
            }
            return true
        case Scancode.delete:
            guard !blockMutations else { return true }
            if !deleteSelection(state: state) {
                guard state.selection.cursorIndex < count else { return true }
                let startByte = text.wrappedValue.utf8Offset(forCharacterIndex: state.selection.cursorIndex)
                let s = text.wrappedValue.delete(characterRange: state.selection.cursorIndex..<(state.selection.cursorIndex + 1))
                text.wrappedValue = s
                state.selection.cursorIndex = s.characterIndex(forUTF8Offset: startByte)
                recordCaretActivity(state)
                events.onChange?(s)
            }
            return true
        case Scancode.arrowLeft:
            if command {
                moveToLineBoundary(ending: false, extendSelection: shift, state: state, node: node)
            } else if option {
                moveCursor(to: wordBoundaryBefore(in: text.wrappedValue,
                                                  offset: state.selection.cursorIndex),
                           extendSelection: shift, state: state)
            } else if !shift, let r = selectionRange(state) {
                state.selection.anchor = nil
                state.selection.cursorIndex = r.lowerBound
                recordCaretActivity(state)
            } else {
                moveCursor(to: state.selection.cursorIndex - 1, extendSelection: shift, state: state)
            }
            return true
        case Scancode.arrowRight:
            if command {
                moveToLineBoundary(ending: true, extendSelection: shift, state: state, node: node)
            } else if option {
                moveCursor(to: wordBoundaryAfter(in: text.wrappedValue,
                                                 offset: state.selection.cursorIndex),
                           extendSelection: shift, state: state)
            } else if !shift, let r = selectionRange(state) {
                state.selection.anchor = nil
                state.selection.cursorIndex = r.upperBound
                recordCaretActivity(state)
            } else {
                moveCursor(to: state.selection.cursorIndex + 1, extendSelection: shift, state: state)
            }
            return true
        case Scancode.home:
            if primaryModifier { moveCursor(to: 0, extendSelection: shift, state: state) }
            else { moveToLineBoundary(ending: false, extendSelection: shift, state: state, node: node) }
            return true
        case Scancode.end:
            if primaryModifier { moveCursor(to: count, extendSelection: shift, state: state) }
            else { moveToLineBoundary(ending: true, extendSelection: shift, state: state, node: node) }
            return true
        case Scancode.arrowUp:
            if command { moveCursor(to: 0, extendSelection: shift, state: state) }
            else { moveCursorVertically(lineDelta: -1, extendSelection: shift, state: state, node: node) }
            return true
        case Scancode.arrowDown:
            if command { moveCursor(to: count, extendSelection: shift, state: state) }
            else { moveCursorVertically(lineDelta: 1, extendSelection: shift, state: state, node: node) }
            return true
        case Scancode.pageUp:
            return moveCursorByPage(direction: -1, extendSelection: shift, state: state, node: node)
        case Scancode.pageDown:
            return moveCursorByPage(direction: 1, extendSelection: shift, state: state, node: node)
        case Scancode.return, Scancode.keypadEnter:
            if !primaryModifier, !blockMutations, (self.layout.axis == .vertical || shift) {
                insertReplacingSelection(indentedNewline(state: state), state: state)
            } else {
                events.onSubmit?()
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Render

    private func render(node: Node,
                        state: FieldState,
                        list: DrawList,
                        origin: CGPoint,
                        interactionState: _TextFieldInteractionState) {
        state.pointer.lastDrawOrigin = origin
        guard let env = TextEnvironmentHolder.current else { return }
        let engine = layoutEngine(for: node)
        let theme = node.theme
        let isFocused = interactionState.isFocused
        let current = text.wrappedValue
        state.buffer = current
        updateAccessibilityValue(on: node, buffer: current)
        let resolvedFont = resolvedFont(node: node, env: env)
        let resolvedLineHeight = resolvedLineHeight(node: node, env: env)
        let resolvedPlaceholderColor = decoration.placeholderColor ?? theme.textEmphasis.placeholder ?? theme.colors.onSurfaceMuted
        let resolvedCursorColor = decoration.cursorColor ?? theme.colors.onSurface
        let resolvedSelectionColor = decoration.selectionColor ?? theme.colors.selection
        let renderState = engine.makeRenderState(current: current, state: state, isFocused: isFocused)
        let renderBaseColor: Color =
            renderState.showsPlaceholder
                ? resolvedPlaceholderColor
                : (behavior.disabled ? theme.textEmphasis.disabled : nil) ?? decoration.textColor ?? node.foregroundColor ?? theme.colors.onSurface
        let renderColor = renderBaseColor.multipliedAlpha(node.opacity)

        let insetX = horizontalInset(theme: theme)
        let frameWidth = Float(node.frame.width)
        let frameHeight = Float(node.frame.height)
        // Compose addon insets first so caret math, hit-testing, clear icon,
        // counter, and the editable text region all reference the same
        // leading / trailing reservations.
        let addonLeading = leadingAddonWidth(env: env, font: resolvedFont,
                                             lineHeight: resolvedLineHeight, theme: theme)
        let addonTrailing = trailingAddonWidth(env: env, font: resolvedFont,
                                               lineHeight: resolvedLineHeight, theme: theme)
        let controlWidth = trailingControlWidth(isFocused: isFocused, env: env, font: resolvedFont,
                                                lineHeight: resolvedLineHeight, theme: theme)
        let renderCache = engine.cachedRenderLayout(node: node,
                                state: state,
                                env: env,
                                renderState: renderState,
                                font: resolvedFont,
                                lineHeight: resolvedLineHeight,
                                availableTextWidth: max(0, frameWidth - insetX * 2 - addonLeading - addonTrailing - controlWidth))
        // Reserve trailing-edge real estate for clear icon + counter so the
        // text/caret never collide with the affordances. Both the visual draw
        // and the hit-test rely on this same reservation.
        let showClear = behavior.clearable && !behavior.disabled && !behavior.readOnly && !current.isEmpty && isFocused
        let counterText: String?
        if decoration.showWordLimit, let maxLength = behavior.maxLength {
            counterText = "\(current.characterCount)/\(maxLength)"
        } else {
            counterText = nil
        }
        let counterLayout: TextLayoutResult?
        if let counterText {
            counterLayout = env.cachedLayout(text: counterText,
                                             font: resolvedFont,
                                             lineHeight: resolvedLineHeight,
                                             maxWidth: .infinity,
                                             alignment: .leading)
        } else {
            counterLayout = nil
        }


        let viewport = engine.updateViewport(node: node,
                                             state: state,
                                             origin: origin,
                                             env: env,
                                             renderState: renderState,
                                             renderCache: renderCache,
                                             font: resolvedFont,
                                             lineHeight: resolvedLineHeight,
                                             addonLeading: addonLeading,
                                             addonTrailing: addonTrailing)
        let textOriginX = viewport.textOriginX
        let textOriginY = viewport.textOriginY

        // Paint prepend / append slabs and inline prefix / suffix glyphs.
        // Slabs draw under the text; inline glyphs are foreground tokens that
        // share the muted on-surface colour so they read as decoration.
        let inputs = theme.inputs
        let slabColor = inputs.addonBackground.multipliedAlpha(node.opacity)
        let dividerColor = inputs.dividerColor.multipliedAlpha(node.opacity)
        let glyphColor = inputs.addonForeground.multipliedAlpha(node.opacity)
        if let prepend = decoration.prepend, !prepend.isEmpty {
            let layout = env.cachedLayout(text: prepend, font: resolvedFont,
                                          lineHeight: resolvedLineHeight,
                                          maxWidth: .infinity, alignment: .leading)
            let slabWidth = layout.totalWidth + insetX * 2
            let slabRect = UIRect(x: Float(origin.x),
                                  y: Float(origin.y),
                                  width: slabWidth, height: frameHeight)
            list.addRect(slabRect, color: slabColor)
            list.addRect(UIRect(x: Float(origin.x) + slabWidth,
                                y: Float(origin.y),
                                width: 1, height: frameHeight),
                         color: dividerColor)
            list.addText(layout,
                         origin: (Float(origin.x) + insetX, textOriginY),
                         color: glyphColor,
                         textureID: env.atlasTextureID,
                         atlas: env.atlas)
        }
        if let append = decoration.append, !append.isEmpty {
            let layout = env.cachedLayout(text: append, font: resolvedFont,
                                          lineHeight: resolvedLineHeight,
                                          maxWidth: .infinity, alignment: .leading)
            let slabWidth = layout.totalWidth + insetX * 2
            let slabX = Float(origin.x) + frameWidth - slabWidth
            list.addRect(UIRect(x: slabX, y: Float(origin.y),
                                width: slabWidth, height: frameHeight),
                         color: slabColor)
            list.addRect(UIRect(x: slabX - 1, y: Float(origin.y),
                                width: 1, height: frameHeight),
                         color: dividerColor)
            list.addText(layout,
                         origin: (slabX + insetX, textOriginY),
                         color: glyphColor,
                         textureID: env.atlasTextureID,
                         atlas: env.atlas)
        }
        if let prefix = decoration.prefix, !prefix.isEmpty {
            let prependWidth: Float = {
                guard let prepend = decoration.prepend, !prepend.isEmpty else { return 0 }
                let layout = env.cachedLayout(text: prepend, font: resolvedFont,
                                              lineHeight: resolvedLineHeight,
                                              maxWidth: .infinity, alignment: .leading)
                return layout.totalWidth + insetX * 2 + theme.spacing.sm
            }()
            let layout = env.cachedLayout(text: prefix, font: resolvedFont,
                                          lineHeight: resolvedLineHeight,
                                          maxWidth: .infinity, alignment: .leading)
            list.addText(layout,
                         origin: (Float(origin.x) + insetX + prependWidth, textOriginY),
                         color: glyphColor,
                         textureID: env.atlasTextureID,
                         atlas: env.atlas)
        }
        if let suffix = decoration.suffix, !suffix.isEmpty {
            let appendWidth: Float = {
                guard let append = decoration.append, !append.isEmpty else { return 0 }
                let layout = env.cachedLayout(text: append, font: resolvedFont,
                                              lineHeight: resolvedLineHeight,
                                              maxWidth: .infinity, alignment: .leading)
                return layout.totalWidth + insetX * 2 + theme.spacing.sm
            }()
            let layout = env.cachedLayout(text: suffix, font: resolvedFont,
                                          lineHeight: resolvedLineHeight,
                                          maxWidth: .infinity, alignment: .leading)
            // Suffix sits before the clear/counter affordances so the order
            // visually matches Element: [text]   [suffix] [counter] [×] [|append].
            let suffixRight = Float(origin.x) + frameWidth - insetX - appendWidth
                - (counterLayout?.totalWidth ?? 0) - (counterLayout != nil ? theme.spacing.xs : 0)
                - (showClear ? resolvedLineHeight + theme.spacing.xs : 0)
            list.addText(layout,
                         origin: (suffixRight - layout.totalWidth, textOriginY),
                         color: glyphColor,
                         textureID: env.atlasTextureID,
                         atlas: env.atlas)
        }

        let visibleLayout = engine.visibleLayout(from: renderCache.layout,
                                                 scrollOffsetY: state.scroll.offsetY,
                                                 visibleHeight: state.scroll.visibleHeight,
                                                 lineHeight: resolvedLineHeight)
        let fixedTextOriginX = textOriginX + state.scroll.horizontal.offset
        if codeEditing.showsLineNumbers && self.layout.axis == .vertical {
            drawLineNumbers(visibleLayout, source: current, origin: origin,
                            textOriginX: fixedTextOriginX, textOriginY: textOriginY,
                            frameHeight: frameHeight, lineHeight: resolvedLineHeight,
                            node: node, env: env, font: resolvedFont, list: list)
        }
        let textClip = UIRect(x: fixedTextOriginX, y: Float(origin.y),
                              width: viewport.availableTextWidth, height: frameHeight)
        list.pushClip(textClip)
        // Selection highlight first (drawn under the glyphs).
        if isFocused, !renderState.isComposing, let range = selectionRange(state), !current.isEmpty {
            engine.drawSelection(range,
                                 in: current,
                                 env: env,
                                 font: resolvedFont,
                                 lineHeight: resolvedLineHeight,
                                 layout: renderCache.layout,
                                 textOriginX: textOriginX,
                                 textOriginY: textOriginY,
                                 visibleTopY: state.scroll.offsetY,
                                 visibleBottomY: state.scroll.offsetY + state.scroll.visibleHeight,
                                 list: list,
                                 color: resolvedSelectionColor.multipliedAlpha(node.opacity))
        }

        list.addText(visibleLayout,
                     origin: (textOriginX, textOriginY),
                     color: renderColor,
                     textureID: env.atlasTextureID,
                     atlas: env.atlas,
                     colorForGlyph: { glyph in
            guard !renderState.showsPlaceholder,
                  !renderState.isComposing,
                  let syntaxColor = codeEditing.syntaxColorAtUTF8Offset?(current, Int(glyph.cluster)) else {
                return nil
            }
            return syntaxColor.multipliedAlpha(node.opacity)
        })

        if !renderState.showsPlaceholder, !renderState.isComposing {
            TextDiagnosticGeometry.draw(TextDiagnosticGeometry.segments(in: visibleLayout,
                diagnostics: codeEditing.diagnostics, lineHeight: resolvedLineHeight),
                origin: (textOriginX, textOriginY), opacity: node.opacity, theme: theme, list: list)
        }
        list.popClip()

        // Draw counter and clear icon at the trailing edge.
        // Push the clear/counter affordances inside the append slab so they
        // visually sit inside the editable region rather than over the addon.
        let trailingRightEdge = Float(origin.x) + frameWidth - insetX - addonTrailing
        var trailingCursor = trailingRightEdge
        if let counterLayout, let _ = counterText {
            let counterX = trailingCursor - counterLayout.totalWidth
            list.addText(counterLayout,
                         origin: (counterX, textOriginY),
                         color: resolvedPlaceholderColor.multipliedAlpha(node.opacity),
                         textureID: env.atlasTextureID,
                         atlas: env.atlas)
            trailingCursor = counterX - theme.spacing.xs
        }
        if showClear {
            let glyphSize = resolvedLineHeight
            let clearX = trailingCursor - glyphSize
            // Cache the hit boundary so pointer-down on the right edge can
            // route to performClear before falling through to caret placement.
            state.pointer.clearHitX = clearX
            drawClearGlyph(at: clearX,
                           y: textOriginY,
                           size: glyphSize,
                           list: list,
                           color: resolvedPlaceholderColor.multipliedAlpha(node.opacity))
        } else {
            state.pointer.clearHitX = nil
        }
        list.pushClip(textClip)
        defer { list.popClip() }
        if isFocused, let compositionRange = renderState.compositionRange {
            engine.drawUnderline(compositionRange,
                                 in: renderState.buffer,
                                 env: env,
                                 font: resolvedFont,
                                 lineHeight: resolvedLineHeight,
                                 layout: renderCache.layout,
                                 textOriginX: textOriginX,
                                 textOriginY: textOriginY,
                                 visibleTopY: state.scroll.offsetY,
                                 visibleBottomY: state.scroll.offsetY + state.scroll.visibleHeight,
                                 list: list,
                                 color: resolvedCursorColor.multipliedAlpha(node.opacity * 0.8))
        }

        let caret = viewport.rawCaret
        let caretX = textOriginX + caret.x
        let caretY = textOriginY + caret.topY
        node.firstResource(TextCompletionSession.self)?.updateAnchor(CGRect(x: CGFloat(caretX), y: CGFloat(caretY), width: 1, height: CGFloat(resolvedLineHeight)))

        // Cursor — suppressed while a non-empty selection is active.
        guard isFocused, renderState.isComposing || selectionRange(state) == nil else { return }
        guard isCaretVisible(state) else { return }
        let cursorRect = UIRect(
            x: caretX,
            y: caretY,
            width: 1,
            height: resolvedLineHeight
        )
        list.addRect(cursorRect, color: resolvedCursorColor.multipliedAlpha(node.opacity))
    }

    func committedTextInputArea(node: Node,
                                state: FieldState,
                                absoluteOrigin: CGPoint,
                                isFocused: Bool) -> TextInputArea? {
        state.pointer.lastDrawOrigin = absoluteOrigin
        guard let env = TextEnvironmentHolder.current else { return nil }

        let current = text.wrappedValue
        state.buffer = current
        updateAccessibilityValue(on: node, buffer: current)
        let resolvedFont = resolvedFont(node: node, env: env)
        let resolvedLineHeight = resolvedLineHeight(node: node, env: env)
        let insetX = horizontalInset(theme: node.theme)
        let frameWidth = Float(node.frame.width)
        let addonLeading = leadingAddonWidth(env: env,
                                             font: resolvedFont,
                                             lineHeight: resolvedLineHeight,
                                             theme: node.theme)
        let addonTrailing = trailingAddonWidth(env: env,
                                               font: resolvedFont,
                                               lineHeight: resolvedLineHeight,
                                               theme: node.theme)
        let renderState = layoutEngine(for: node).makeRenderState(current: current,
                                                       state: state,
                                                       isFocused: isFocused)
        let renderCache = layoutEngine(for: node).cachedRenderLayout(node: node,
                                state: state,
                                                          env: env,
                                renderState: renderState,
                                                          font: resolvedFont,
                                                          lineHeight: resolvedLineHeight,
                                                          availableTextWidth: max(0,
                                                                                  frameWidth
                                                                                  - insetX * 2
                                                                                  - addonLeading
                                                                                  - addonTrailing
                                                                                  - trailingControlWidth(isFocused: isFocused, env: env, font: resolvedFont,
                                                                                      lineHeight: resolvedLineHeight, theme: node.theme)))
        let viewport = layoutEngine(for: node).updateViewport(node: node,
                                                   state: state,
                                                   origin: absoluteOrigin,
                                                   env: env,
                                                   renderState: renderState,
                                                   renderCache: renderCache,
                                                   font: resolvedFont,
                                                   lineHeight: resolvedLineHeight,
                                                   addonLeading: addonLeading,
                                                   addonTrailing: addonTrailing)
        let caret = viewport.rawCaret
        return TextInputArea(
            x: viewport.textOriginX + caret.x,
            y: viewport.textOriginY + caret.topY,
            width: max(1, resolvedLineHeight),
            height: resolvedLineHeight,
            cursorX: 0
        )
    }

    func refreshScrollableMetrics(state: FieldState, node: Node) {
        guard let env = TextEnvironmentHolder.current else { return }

        let isFocused = (FocusChainHolder.current?.focused === node)
        let current = text.wrappedValue
        state.buffer = current
        updateAccessibilityValue(on: node, buffer: current)
        let resolvedFont = resolvedFont(node: node, env: env)
        let resolvedLineHeight = resolvedLineHeight(node: node, env: env)
        let insetX = horizontalInset(theme: node.theme)
        let addonLeading = leadingAddonWidth(env: env,
                                             font: resolvedFont,
                                             lineHeight: resolvedLineHeight,
                                             theme: node.theme)
        let addonTrailing = trailingAddonWidth(env: env,
                                               font: resolvedFont,
                                               lineHeight: resolvedLineHeight,
                                               theme: node.theme)
        let renderState = layoutEngine(for: node).makeRenderState(current: current,
                                                       state: state,
                                                       isFocused: isFocused)
        let renderCache = layoutEngine(for: node).cachedRenderLayout(node: node,
                                state: state,
                                                          env: env,
                                renderState: renderState,
                                                          font: resolvedFont,
                                                          lineHeight: resolvedLineHeight,
                                                          availableTextWidth: max(0,
                                                                                  Float(node.frame.width)
                                                                                  - insetX * 2
                                                                                  - addonLeading
                                                                                  - addonTrailing
                                                                                  - trailingControlWidth(isFocused: isFocused, env: env, font: resolvedFont,
                                                                                      lineHeight: resolvedLineHeight, theme: node.theme)))
        layoutEngine(for: node).refreshScrollMetrics(node: node,
                                          state: state,
                                          renderCache: renderCache,
                                          lineHeight: resolvedLineHeight)
    }

    private func isCaretVisible(_ state: FieldState) -> Bool {
        let elapsed = TimingTrace.now() - state.lastCaretActivity
        if elapsed <= Self.caretBlinkSteadyDuration {
            return true
        }

        let phaseLength = Self.caretBlinkHalfPeriod * 2
        let phase = (elapsed - Self.caretBlinkSteadyDuration)
            .truncatingRemainder(dividingBy: phaseLength)
        return phase < Self.caretBlinkHalfPeriod
    }

    /// Snap the cursor to the character boundary nearest a window-space point.
    /// Convenience wrapper around `characterIndex(atWindowX:)` that also
    /// writes the result back to `state.selection.cursorIndex`.
    private func positionCursor(atWindowPoint point: CGPoint,
                                state: FieldState,
                                node: Node) {
        state.selection.cursorIndex = layoutEngine(for: node).characterIndex(atWindowPoint: point, state: state, node: node)
    }

    /// Map a window-space point to a character index.
    /// Treats glyph index as character index — accurate for ASCII; ligatures,
    /// CJK, and emoji are still approximate.
    func characterIndex(atWindowPoint point: CGPoint,
                        state: FieldState,
                        node: Node) -> Int {
        layoutEngine(for: node).characterIndex(atWindowPoint: point, state: state, node: node)
    }

    // MARK: - Pointer / multi-click

    /// Handle a pointer-down event: dispatch to single-click cursor placement,
    /// double-click word selection, or triple-click select-all based on
    /// `event.clicks` (set by SDL3 to 1 / 2 / 3 for the click cadence).
    func handlePointerDown(event: MouseButtonEvent,
                           state: FieldState,
                           node: Node) {
        switch event.clicks {
        case 3...:
            // Triple click: select the entire field.
            state.selection.anchor = 0
            state.selection.cursorIndex = text.wrappedValue.characterCount
            state.pointer.isDragging = false
        case 2:
            // Double click: select the word under the cursor.
            let target = characterIndex(atWindowPoint: CGPoint(x: CGFloat(event.x),
                                                               y: CGFloat(event.y)),
                                        state: state,
                                        node: node)
            let (lo, hi) = wordBounds(in: text.wrappedValue, around: target)
            state.selection.anchor = lo
            state.selection.cursorIndex = hi
            state.pointer.isDragging = false
        default:
            // Single click: place the cursor and start a drag selection.
            state.selection.anchor = nil
            positionCursor(atWindowPoint: CGPoint(x: CGFloat(event.x),
                                                  y: CGFloat(event.y)),
                           state: state,
                           node: node)
            state.pointer.isDragging = true
            PointerCaptureHolder.current?.acquire(node)
        }
        recordCaretActivity(state)
    }

    func horizontalInset(theme: Theme) -> Float {
        max(4, theme.spacing.sm)
    }

    /// Width consumed by `prepend` slab + `prefix` glyph at the leading edge,
    /// inclusive of inter-element spacing. Returns 0 when no slot is set so
    /// callers can add this unconditionally.
    func leadingAddonWidth(env: TextEnvironment,
                           font: Font,
                           lineHeight: Float,
                           theme: Theme) -> Float {
        var width: Float = 0
        if let prepend = decoration.prepend, !prepend.isEmpty {
            let layout = env.cachedLayout(text: prepend, font: font, lineHeight: lineHeight,
                                          maxWidth: .infinity, alignment: .leading)
            // Slab paddings (left + right) are theme.spacing.sm on each side.
            width += layout.totalWidth + horizontalInset(theme: theme) * 2 + theme.spacing.sm
        }
        if let prefix = decoration.prefix, !prefix.isEmpty {
            let layout = env.cachedLayout(text: prefix, font: font, lineHeight: lineHeight,
                                          maxWidth: .infinity, alignment: .leading)
            width += layout.totalWidth + theme.spacing.xs
        }
        width += lineNumberGutterWidth(env: env,
                                       font: font,
                                       lineHeight: lineHeight,
                                       theme: theme)
        return width
    }

    private func lineNumberGutterWidth(env: TextEnvironment,
                                       font: Font,
                                       lineHeight: Float,
                                       theme: Theme) -> Float {
        guard codeEditing.showsLineNumbers, self.layout.axis == .vertical else { return 0 }
        let lineCount = text.wrappedValue.lineCount
        let numberFont = Font.system(size: max(9, font.size - 2))
        let numberLayout = env.cachedLayout(text: String(repeating: "8", count: String(lineCount).count),
                                            font: numberFont,
                                            lineHeight: lineHeight,
                                            maxWidth: .infinity,
                                            alignment: .trailing)
        return numberLayout.totalWidth + theme.spacing.md
    }

    private func drawLineNumbers(_ layout: TextLayoutResult,
                                 source: TextBuffer,
                                 origin: CGPoint,
                                 textOriginX: Float,
                                 textOriginY: Float,
                                 frameHeight: Float,
                                 lineHeight: Float,
                                 node: Node,
                                 env: TextEnvironment,
                                 font: Font,
                                 list: DrawList) {
        let theme = node.theme
        let gutterWidth = lineNumberGutterWidth(env: env,
                                                font: font,
                                                lineHeight: lineHeight,
                                                theme: theme)
        guard gutterWidth > 0 else { return }
        let gutterX = textOriginX - gutterWidth
        list.addRect(UIRect(x: gutterX,
                            y: Float(origin.y),
                            width: gutterWidth,
                            height: frameHeight),
                     color: (codeEditing.lineNumberGutterColor ?? theme.colors.surfaceVariant)
                        .multipliedAlpha(node.opacity))
        list.addRect(UIRect(x: textOriginX - 1,
                            y: Float(origin.y),
                            width: 1,
                            height: frameHeight),
                     color: theme.colors.onSurfaceMuted.multipliedAlpha(node.opacity * 0.22))

        let numberFont = Font.system(size: max(9, font.size - 2))
        var lastLineNumber = 0
        for line in layout.lines {
            let lineNumber = source.lineIndex(forCharacterIndex: source.characterIndex(forUTF8Offset: Int(line.startCluster))) + 1
            guard lineNumber != lastLineNumber else { continue }
            lastLineNumber = lineNumber
            let numberLayout = env.cachedLayout(text: String(lineNumber),
                                                font: numberFont,
                                                lineHeight: lineHeight,
                                                maxWidth: .infinity,
                                                alignment: .trailing)
            let numberBaseline = numberLayout.lines.first?.baselineY ?? lineHeight
            list.addText(numberLayout,
                         origin: (gutterX + gutterWidth - theme.spacing.xs - numberLayout.totalWidth,
                                  textOriginY + line.baselineY - numberBaseline),
                         color: (codeEditing.lineNumberColor ?? theme.colors.onSurfaceMuted)
                            .multipliedAlpha(node.opacity),
                         textureID: env.atlasTextureID,
                         atlas: env.atlas)
        }
    }

    /// Width consumed by `suffix` glyph + `append` slab at the trailing edge.
    /// Excludes the dynamic clearable / counter widths since those are sized
    /// per-frame in `render`.
    func trailingAddonWidth(env: TextEnvironment,
                            font: Font,
                            lineHeight: Float,
                            theme: Theme) -> Float {
        var width: Float = 0
        if let suffix = decoration.suffix, !suffix.isEmpty {
            let layout = env.cachedLayout(text: suffix, font: font, lineHeight: lineHeight,
                                          maxWidth: .infinity, alignment: .leading)
            width += layout.totalWidth + theme.spacing.xs
        }
        if let append = decoration.append, !append.isEmpty {
            let layout = env.cachedLayout(text: append, font: font, lineHeight: lineHeight,
                                          maxWidth: .infinity, alignment: .leading)
            width += layout.totalWidth + horizontalInset(theme: theme) * 2 + theme.spacing.sm
        }
        return width
    }

    func trailingControlWidth(isFocused: Bool, env: TextEnvironment, font: Font,
                              lineHeight: Float, theme: Theme) -> Float {
        var width: Float = 0
        if behavior.clearable, !behavior.disabled, !behavior.readOnly, !text.wrappedValue.isEmpty, isFocused {
            width += lineHeight + theme.spacing.xs
        }
        if decoration.showWordLimit, let maximum = behavior.maxLength {
            width += env.cachedLayout(text: "\(text.wrappedValue.characterCount)/\(maximum)", font: font,
                lineHeight: lineHeight, maxWidth: .infinity, alignment: .leading).totalWidth + theme.spacing.xs
        }
        return width
    }

    func textOriginYOffset(frameHeight: Float, lineHeight: Float) -> Float {
        if self.layout.axis == .vertical {
            return Self.verticalInset(for: lineHeight)
        }
        return max(0, (frameHeight - lineHeight) / 2)
    }

    static func verticalInset(for lineHeight: Float) -> Float {
        max(4, (minimumFieldHeightDefault - lineHeight) * 0.5)
    }

    /// Render the clear affordance at `(x, y)` using the bundled close SVG so
    /// it matches every other icon. Falls back silently when no registry or
    /// resource is available (headless tests).
    private func drawClearGlyph(at x: Float,
                                y: Float,
                                size: Float,
                                list: DrawList,
                                color: Color) {
        guard let url = UICommonIcons.close.url,
              let registry = ImageAssetRegistryHolder.current else { return }
        let scale = max(1, ContentScaleHolder.current)
        let side = size * 0.7
        let px = max(1, Int((side * scale).rounded()))
        guard let asset = try? registry.texture(url: url, size: (px, px)) else { return }
        let inset = (size - side) * 0.5
        list.addImageMaskQuad(rect: UIRect(x: x + inset,
                                           y: y + inset,
                                           width: side,
                                           height: side),
                              textureID: asset.textureID,
                              tint: color)
    }

    private static func installMeasureFunc(on layout: LayoutNode, snapshot: TextField) {
        guard snapshot.layout.axis == .vertical else {
            layout.setMeasureFunc { [weak layout] width, mode, _, _ in
                let ideal = snapshot.layout.idealWidth.isFinite ? max(1, snapshot.layout.idealWidth) : 160
                let resolved = mode == .exactly ? width : mode == .atMost ? min(ideal, max(0, width)) : ideal
                return CGSize(width: CGFloat(resolved), height: CGFloat(snapshot.resolvedFieldHeight(layout: layout)))
            }
            return
        }

        layout.setMeasureFunc { [weak layout] width, widthMode, _, _ in
            guard let env = TextEnvironmentHolder.current else {
                return CGSize(width: 0, height: CGFloat(snapshot.minimumFieldHeight))
            }
            let fontOverride = layout?.textStyleValue(StyleAttachmentKey.font) as Font?
            let lineHeightOverride = layout?.textStyleValue(StyleAttachmentKey.lineHeight) as Float?
            let resolvedFont = env.resolvedFont(fontOverride ?? snapshot.sizeFontSize.map { Font.system(size: $0) })
            let resolvedLineHeight = env.resolvedLineHeight(font: resolvedFont,
                                                            override: lineHeightOverride)
            let buffer = snapshot.text.wrappedValue.isEmpty ? TextBuffer(snapshot.placeholder) : snapshot.text.wrappedValue
            let widthLimit = widthMode == .undefined || !snapshot.layout.wrapsLines ? Float.infinity : max(1, width - 16)
            let geometry = TextLineGeometry(font: resolvedFont, lineHeight: resolvedLineHeight,
                                            letterSpacing: layout?.textStyleValue(StyleAttachmentKey.letterSpacing) ?? 0,
                                            atlas: ObjectIdentifier(env.atlas), width: widthLimit,
                                            secure: snapshot.behavior.secure && !snapshot.text.wrappedValue.isEmpty)
            let document: TextDocumentLayout
            if let cached = layout?.attachments["__textfield_measure_document_layout"] as? TextDocumentLayout {
                cached.update(buffer: buffer, geometry: geometry); document = cached
            } else {
                document = TextDocumentLayout(buffer: buffer, geometry: geometry)
                layout?.attachments["__textfield_measure_document_layout"] = document
            }
            let layoutResult = document.visibleLayout(firstRow: 0, rowCount: snapshot.layout.maxVisibleLines + 1, environment: env)

            let insetY = verticalInset(for: resolvedLineHeight)
            let contentHeight = max(resolvedLineHeight, layoutResult.totalHeight)
            let measuredWidth = layoutResult.totalWidth + 16
            let resolvedWidth: Float
            switch widthMode {
            case .exactly:
                resolvedWidth = width
            case .atMost:
                resolvedWidth = min(measuredWidth, width)
            case .undefined:
                resolvedWidth = measuredWidth
            }

            let maxHeight = max(snapshot.minimumFieldHeight,
                                resolvedLineHeight * Float(snapshot.layout.maxVisibleLines) + insetY * 2)

            return CGSize(width: CGFloat(resolvedWidth),
                          height: CGFloat(min(max(snapshot.minimumFieldHeight,
                                                  contentHeight + insetY * 2),
                                              maxHeight)))
        }
    }

    private func resolvedFieldHeight(layout: LayoutNode?) -> Float {
        guard self.layout.axis != .vertical else {
            return minimumFieldHeight
        }
        let lineCount = text.wrappedValue.isEmpty ? TextBuffer(placeholder).lineCount : text.wrappedValue.lineCount
        guard self.layout.axis == .vertical || lineCount > 1 else {
            return minimumFieldHeight
        }
        guard let env = TextEnvironmentHolder.current else {
            return minimumFieldHeight
        }

        let fontOverride = layout?.textStyleValue(StyleAttachmentKey.font) as Font?
        let lineHeightOverride = layout?.textStyleValue(StyleAttachmentKey.lineHeight) as Float?
        let resolvedFont = env.resolvedFont(fontOverride ?? sizeFontSize.map { Font.system(size: $0) })
        let resolvedLineHeight = env.resolvedLineHeight(font: resolvedFont,
                                                        override: lineHeightOverride)
        let insetY = Self.verticalInset(for: resolvedLineHeight)
        let contentHeight = Float(lineCount) * resolvedLineHeight
        let maxHeight = max(minimumFieldHeight,
                            resolvedLineHeight * Float(self.layout.maxVisibleLines) + insetY * 2)
        return min(max(minimumFieldHeight, contentHeight + insetY * 2), maxHeight)
    }

    func resolvedFont(node: Node, env: TextEnvironment) -> Font {
        env.resolvedFont((node.textStyleValue(StyleAttachmentKey.font) as Font?)
            ?? sizeFontSize.map { Font.system(size: $0) })
    }

    func resolvedLineHeight(node: Node, env: TextEnvironment) -> Float {
        env.resolvedLineHeight(
            font: resolvedFont(node: node, env: env),
            override: node.textStyleValue(StyleAttachmentKey.lineHeight) as Float?
        )
    }

    /// Word navigation visits only the run surrounding the cursor, through
    /// Rope lookups; it never materializes the document.
    private func wordBounds(in buffer: TextBuffer, around index: Int) -> (Int, Int) {
        guard !buffer.isEmpty else { return (0, 0) }
        let cursor = clamp(index, 0, buffer.characterCount - 1)
        let kind = wordKind(buffer.character(at: cursor)!)
        var lower = cursor, upper = cursor + 1
        while lower > 0, wordKind(buffer.character(at: lower - 1)!) == kind { lower -= 1 }
        while upper < buffer.characterCount, wordKind(buffer.character(at: upper)!) == kind { upper += 1 }
        return (lower, upper)
    }

    private enum CharKind { case word, space, other }
    private func wordKind(_ c: Character) -> CharKind {
        if c.isLetter || c.isNumber || c == "_" { return .word }
        if c.isWhitespace { return .space }
        return .other
    }

    /// Option+Left / Option+Backspace target: skip any whitespace immediately
    /// before the caret, then the run of same-kind characters before it.
    func wordBoundaryBefore(in buffer: TextBuffer, offset: Int) -> Int {
        var cursor = clamp(offset, 0, buffer.characterCount)
        while cursor > 0, wordKind(buffer.character(at: cursor - 1)!) == .space { cursor -= 1 }
        guard cursor > 0 else { return 0 }
        let kind = wordKind(buffer.character(at: cursor - 1)!)
        while cursor > 0, wordKind(buffer.character(at: cursor - 1)!) == kind { cursor -= 1 }
        return cursor
    }
    func wordBoundaryAfter(in buffer: TextBuffer, offset: Int) -> Int {
        var cursor = clamp(offset, 0, buffer.characterCount)
        while cursor < buffer.characterCount, wordKind(buffer.character(at: cursor)!) == .space { cursor += 1 }
        guard cursor < buffer.characterCount else { return buffer.characterCount }
        let kind = wordKind(buffer.character(at: cursor)!)
        while cursor < buffer.characterCount, wordKind(buffer.character(at: cursor)!) == kind { cursor += 1 }
        return cursor
    }
}

@inline(__always)
func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
    min(max(v, lo), hi)
}
