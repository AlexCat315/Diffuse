#if canImport(CoreGraphics)
import CoreGraphics
#endif
import EngineKernel
import GuavaUIRuntime

/// Text input field. The default horizontal axis is single-line; the
/// vertical axis accepts explicit newline insertion and grows in height to fit
/// those lines.
///
/// Editing history and selection live on the retained surface node. Primary-Z
/// and Primary-Shift-Z undo/redo text before application shortcuts run.
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

    public let text: Binding<String>
    public let placeholder: String
    public let axis: Axis
    public let maxVisibleLines: Int
    public let showsLineNumbers: Bool
    public let lineNumberColor: Color?
    /// Gutter background behind the line numbers. `nil` falls back to the
    /// theme's `surfaceVariant`, which suits light inputs; code editors on a
    /// dark surface pass their own tint so the gutter reads as part of the
    /// code panel rather than a separate light strip.
    public let lineNumberGutterColor: Color?
    public let syntaxColorAtUTF8Offset: ((String, Int) -> Color?)?
    public var size: Size
    public let disabled: Bool
    public let readOnly: Bool
    public let secure: Bool
    public let clearable: Bool
    public let maxLength: Int?
    public let showWordLimit: Bool
    /// Element-style `prefix` / `suffix`: short text painted *inside* the
    /// field at the leading / trailing edge (icons are rendered as glyph text
    /// — pass an emoji or single character). They share the input surface.
    public let prefix: String?
    public let suffix: String?
    /// Element-style `prepend` / `append`: short text painted *outside* the
    /// editable surface (against `surfaceVariant`) and joined to the field
    /// with a divider — for unit labels, currency tags, or trailing buttons
    /// rendered as static text. Single primitive owns the whole frame so
    /// hit-testing stays unchanged.
    public let prepend: String?
    public let append: String?
    /// Changes to this identity request focus and select the entire value.
    /// This is intended for transient inline editors (for example, F2 rename)
    /// where the input must be immediately keyboard-ready after insertion.
    public let focusRequestID: AnyHashable?
    public let onSubmit: (() -> Void)?
    public let onCancel: (() -> Void)?
    public let onChange: ((String) -> Void)?
    /// Pointer resting position inside the field, reported as the pointer moves
    /// whether or not a drag selection is active. Receives `nil` when the
    /// pointer leaves. Used to anchor editor affordances such as hover popups.
    public let onHoverChange: ((TextFieldHoverAnchor?) -> Void)?
    /// Caret and selection movement. Reported through the same funnel as cursor
    /// blinking, so it fires per keystroke as well as per arrow key.
    public let onCaretChange: ((TextFieldCaretState) -> Void)?
    public let onFocus: (() -> Void)?
    public let onBlur: (() -> Void)?
    public let onClear: (() -> Void)?
    public let textColor: Color?
    public let placeholderColor: Color?
    public let cursorColor: Color?
    public let selectionColor: Color?

    public init(_ placeholder: String = "",
                text: Binding<String>,
                axis: Axis = .horizontal,
                maxVisibleLines: Int = 6,
                showsLineNumbers: Bool = false,
                lineNumberColor: Color? = nil,
                lineNumberGutterColor: Color? = nil,
                syntaxColorAtUTF8Offset: ((String, Int) -> Color?)? = nil,
                size: Size = .automatic,
                disabled: Bool = false,
                readOnly: Bool = false,
                secure: Bool = false,
                clearable: Bool = false,
                maxLength: Int? = nil,
                showWordLimit: Bool = false,
                prefix: String? = nil,
                suffix: String? = nil,
                prepend: String? = nil,
                append: String? = nil,
                focusRequestID: AnyHashable? = nil,
                onSubmit: (() -> Void)? = nil,
                onCancel: (() -> Void)? = nil,
                onChange: ((String) -> Void)? = nil,
                onHoverChange: ((TextFieldHoverAnchor?) -> Void)? = nil,
                onCaretChange: ((TextFieldCaretState) -> Void)? = nil,
                onFocus: (() -> Void)? = nil,
                onBlur: (() -> Void)? = nil,
                onClear: (() -> Void)? = nil,
                textColor: Color? = nil,
                placeholderColor: Color? = nil,
                cursorColor: Color? = nil,
                selectionColor: Color? = nil) {
        self.text = text
        self.placeholder = placeholder
        self.axis = axis
        self.maxVisibleLines = max(1, maxVisibleLines)
        self.showsLineNumbers = showsLineNumbers
        self.lineNumberColor = lineNumberColor
        self.lineNumberGutterColor = lineNumberGutterColor
        self.syntaxColorAtUTF8Offset = syntaxColorAtUTF8Offset
        self.size = size
        self.disabled = disabled
        self.readOnly = readOnly
        self.secure = secure
        self.clearable = clearable
        self.maxLength = maxLength
        self.showWordLimit = showWordLimit
        self.prefix = prefix
        self.suffix = suffix
        self.prepend = prepend
        self.append = append
        self.focusRequestID = focusRequestID
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.onChange = onChange
        self.onHoverChange = onHoverChange
        self.onCaretChange = onCaretChange
        self.onFocus = onFocus
        self.onBlur = onBlur
        self.onClear = onClear
        self.textColor = textColor
        self.placeholderColor = placeholderColor
        self.cursorColor = cursorColor
        self.selectionColor = selectionColor
    }

    public var body: some View {
        _StatefulTextField(textField: self)
    }

    private struct MeasureInputs: Equatable {
        let text: String
        let placeholder: String
        let axis: Axis
        let maxVisibleLines: Int
        let showsLineNumbers: Bool
        let secure: Bool
    }

    private struct PaintIdentity: Equatable {
        let text: String
        let placeholder: String
        let axis: Axis
        let size: Size
        let maxVisibleLines: Int
        let showsLineNumbers: Bool
        let lineNumberColor: Color?
        let lineNumberGutterColor: Color?
        let syntaxColoringEnabled: Bool
        let disabled: Bool
        let readOnly: Bool
        let secure: Bool
        let clearable: Bool
        let maxLength: Int?
        let showWordLimit: Bool
        let prefix: String?
        let suffix: String?
        let prepend: String?
        let append: String?
        let textColor: Color?
        let placeholderColor: Color?
        let cursorColor: Color?
        let selectionColor: Color?
        let isFocused: Bool
    }

    private static let minimumFieldHeightDefault: Float = 32
    static let multilineWheelStep: Float = 30
    static let scrollbarTrackThickness: Float = 6
    static let scrollbarInset: Float = 3
    private var minimumFieldHeight: Float {
        switch size {
        case .large:   return 40
        case .automatic, .regular: return 32
        case .small:   return 24
        }
    }
    /// Optional intrinsic font size override applied per `Size` so an
    /// unstyled TextField still picks up a smaller body in the `.small`
    /// variant. Returning `nil` keeps the active TextEnvironment default.
    private var sizeFontSize: Float? {
        switch size {
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
    private var layoutEngine: LayoutEngine { LayoutEngine(textField: self) }

    func _makeNode() -> Node {
        let n = Node()
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
        node.attachments[Self.surfaceMarkerKey] = true
        node.backgroundColor = .clear
        node.cornerRadius = 0
        node.borderColor = .clear
        node.borderWidth = 0
        node.opacity = 1
        node.cursor = disabled ? .arrow : .ibeam
        node.isFocusable = !disabled
        node.isHitTestable = !disabled
        node.clipsToBounds = true
        if node.attachments[Self.scrollbarHoveredKey] == nil {
            node.attachments[Self.scrollbarHoveredKey] = false
        }
        if node.attachments[Self.scrollbarChromeOpacityKey] == nil {
            node.attachments[Self.scrollbarChromeOpacityKey] = Float(0)
        }
        if let sizeFontSize {
            // Seed a sensible default font for size variants when no
            // explicit `.font(...)` modifier was applied.
            if node.attachments[StyleAttachmentKey.font] == nil {
                node.attachments[StyleAttachmentKey.font] = Font.system(size: sizeFontSize)
            }
        }

        // Reuse FieldState if this node is being recycled by reconcile;
        // otherwise create one and seed cursor at the end of the current text.
        let state: FieldState
        if let existing = node.attachments["__textfield_state"] as? FieldState {
            state = existing
        } else {
            state = FieldState()
            state.cursorIndex = text.wrappedValue.count
            node.attachments["__textfield_state"] = state
        }
        state.hostNode = node
        normalizeIndices(state)
        let snapshot = self
        let paintIdentity = PaintIdentity(text: text.wrappedValue,
                                          placeholder: placeholder,
                                          axis: axis,
                                          size: size,
                                          maxVisibleLines: maxVisibleLines,
                                          showsLineNumbers: showsLineNumbers,
                                          lineNumberColor: lineNumberColor,
                                          lineNumberGutterColor: lineNumberGutterColor,
                                          syntaxColoringEnabled: syntaxColorAtUTF8Offset != nil,
                                          disabled: disabled,
                                          readOnly: readOnly,
                                          secure: secure,
                                          clearable: clearable,
                                          maxLength: maxLength,
                                          showWordLimit: showWordLimit,
                                          prefix: prefix,
                                          suffix: suffix,
                                          prepend: prepend,
                                          append: append,
                                          textColor: textColor,
                                          placeholderColor: placeholderColor,
                                          cursorColor: cursorColor,
                                          selectionColor: selectionColor,
                                          isFocused: interactionState.isFocused)

        updateInteractionHandlers(for: node, state: state)
        node.attachments[TextInputAttachmentKey.editActions] = TextEditActions(
            canPerform: { command in
                snapshot.synchronizeHistory(state)
                guard !snapshot.disabled, !snapshot.readOnly else { return false }
                return command == .undo ? !state.undoHistory.isEmpty : !state.redoHistory.isEmpty
            },
            perform: { command in snapshot.restoreEdit(state: state, redo: command == .redo) }
        )
        node.attachments[WheelRoutingAttachmentKey.priority] = interactionState.isFocused
            ? WheelRoutingPriority.preferFocused
            : nil
        node.attachments[TextInputAttachmentKey.focusChangeHandler] = { [weak node] focused in
            state.breakUndoGroup()
            node?.attachments[WheelRoutingAttachmentKey.priority] = focused
                ? WheelRoutingPriority.preferFocused
                : nil
            if !focused, state.isComposing {
                state.clearComposition()
                onEditingChange(false)
            }
            onFocusChange(focused)
            if focused {
                snapshot.onFocus?()
            } else {
                snapshot.onBlur?()
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

        if let focusRequestID,
           node.attachments[Self.focusRequestIDKey] as? AnyHashable != focusRequestID {
            node.attachments[Self.focusRequestIDKey] = focusRequestID
            state.selectionAnchor = 0
            state.cursorIndex = text.wrappedValue.count
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
            guard let node,
                  let metrics = snapshot.layoutEngine.scrollbarMetrics(state: state,
                                                                      node: node,
                                                                      origin: origin)
            else { return }
            let opacity = node.attachments[Self.scrollbarChromeOpacityKey] as? Float ?? 0
            guard opacity > 0.001 else { return }
            let colors = node.theme.colors
            list.addRoundedRect(metrics.trackRect,
                                radius: Self.scrollbarTrackThickness / 2,
                                color: colors.surfaceVariant.multipliedAlpha(node.opacity * opacity))
            list.addRoundedRect(metrics.thumbRect,
                                radius: Self.scrollbarTrackThickness / 2,
                                color: colors.onSurfaceMuted.multipliedAlpha(node.opacity * opacity))
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
                                   axis: axis,
                                   maxVisibleLines: maxVisibleLines,
                                   showsLineNumbers: showsLineNumbers,
                                   secure: secure)
        layout.attachments[Self.measureInputsKey] = inputs
        if axis == .vertical {
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
                                 axis: axis,
                                 maxVisibleLines: maxVisibleLines,
                                 showsLineNumbers: showsLineNumbers,
                                 secure: secure)
        let previous = layout.attachments[Self.measureInputsKey] as? MeasureInputs
        layout.attachments[Self.measureInputsKey] = next
        if axis == .vertical {
            layout.height = nil
            layout.minHeight = minimumFieldHeight
        } else {
            layout.minHeight = nil
            layout.height = resolvedFieldHeight(layout: layout)
        }
        if axis == .vertical {
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
        let mods = event.modifiers
        let shift = !mods.isDisjoint(with: .shift)
        let primaryModifier = !mods.isDisjoint(with: .gui) || !mods.isDisjoint(with: .ctrl)
        // macOS text-navigation idioms: Option = word-wise, Command = line-wise.
        // (Command+arrow reuses the Home/End paths since Mac keyboards have no
        // physical Home/End keys.)
        let option = !mods.isDisjoint(with: [.lalt, .ralt])
        let command = !mods.isDisjoint(with: .gui)
        let count = text.wrappedValue.count
        // In read-only mode the field still accepts caret motion, selection,
        // and primary select/copy shortcuts so users can copy the value, but every mutation
        // (typing, paste, cut, backspace, delete, newline insert) is silently
        // dropped — matching Element Plus' readonly Input behaviour.
        let blockMutations = readOnly

        // Primary shortcuts take priority over plain bindings.
        if primaryModifier {
            switch event.scancode {
            case Scancode.z:
                if !blockMutations { restoreEdit(state: state, redo: shift) }
                return true
            case Scancode.y:
                if !blockMutations { restoreEdit(state: state, redo: true) }
                return true
            case Scancode.a:
                state.breakUndoGroup()
                state.selectionAnchor = 0
                state.cursorIndex = count
                recordCaretActivity(state)
                return true
            case Scancode.c:
                if !secure, let r = selectionRange(state) {
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
                    if !secure {
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
        case Scancode.escape:
            guard let onCancel else { return false }
            onCancel()
            return true
        case Scancode.backspace:
            guard !blockMutations else { return true }
            if !deleteSelection(state: state) {
                guard state.cursorIndex > 0 else { return true }
                // Option deletes to the previous word boundary, Command to the
                // start of the field; plain Backspace removes one character.
                let deleteTo: Int = {
                    if command { return 0 }
                    if option { return wordBoundaryBefore(in: text.wrappedValue,
                                                          offset: state.cursorIndex) }
                    return state.cursorIndex - 1
                }()
                var s = text.wrappedValue
                let lo = s.index(s.startIndex, offsetBy: deleteTo)
                let hi = s.index(s.startIndex, offsetBy: state.cursorIndex)
                s.removeSubrange(lo..<hi)
                applyEdit(s, cursor: deleteTo, state: state)
            }
            return true
        case Scancode.delete:
            guard !blockMutations else { return true }
            if !deleteSelection(state: state) {
                guard state.cursorIndex < count else { return true }
                var s = text.wrappedValue
                let removeAt = s.index(s.startIndex, offsetBy: state.cursorIndex)
                s.remove(at: removeAt)
                applyEdit(s, cursor: state.cursorIndex, state: state)
            }
            return true
        case Scancode.arrowLeft:
            if command {
                moveCursor(to: 0, extendSelection: shift, state: state)
            } else if option {
                moveCursor(to: wordBoundaryBefore(in: text.wrappedValue,
                                                  offset: state.cursorIndex),
                           extendSelection: shift, state: state)
            } else if !shift, let r = selectionRange(state) {
                state.selectionAnchor = nil
                state.cursorIndex = r.lowerBound
                recordCaretActivity(state)
            } else {
                moveCursor(to: state.cursorIndex - 1, extendSelection: shift, state: state)
            }
            return true
        case Scancode.arrowRight:
            if command {
                moveCursor(to: count, extendSelection: shift, state: state)
            } else if option {
                moveCursor(to: wordBoundaryAfter(in: text.wrappedValue,
                                                 offset: state.cursorIndex),
                           extendSelection: shift, state: state)
            } else if !shift, let r = selectionRange(state) {
                state.selectionAnchor = nil
                state.cursorIndex = r.upperBound
                recordCaretActivity(state)
            } else {
                moveCursor(to: state.cursorIndex + 1, extendSelection: shift, state: state)
            }
            return true
        case Scancode.home:
            moveCursor(to: 0, extendSelection: shift, state: state)
            return true
        case Scancode.end:
            moveCursor(to: count, extendSelection: shift, state: state)
            return true
        case Scancode.arrowUp:
            moveCursorVertically(lineDelta: -1, extendSelection: shift, state: state, node: node)
            return true
        case Scancode.arrowDown:
            moveCursorVertically(lineDelta: 1, extendSelection: shift, state: state, node: node)
            return true
        case Scancode.return, Scancode.keypadEnter:
            if !primaryModifier, !blockMutations, (axis == .vertical || shift) {
                insertReplacingSelection("\n", state: state)
            } else {
                onSubmit?()
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
        state.lastDrawOrigin = origin
        guard let env = TextEnvironmentHolder.current else { return }
        let engine = layoutEngine
        let theme = node.theme
        let isFocused = interactionState.isFocused
        let current = text.wrappedValue
        let resolvedFont = resolvedFont(node: node, env: env)
        let resolvedLineHeight = resolvedLineHeight(node: node, env: env)
        let resolvedPlaceholderColor = placeholderColor ?? theme.colors.onSurfaceMuted
        let resolvedCursorColor = cursorColor ?? theme.colors.onSurface
        let resolvedSelectionColor = selectionColor ?? theme.colors.selection
        let renderState = engine.makeRenderState(current: current, state: state, isFocused: isFocused)
        let renderBaseColor: Color =
            renderState.showsPlaceholder
                ? resolvedPlaceholderColor
                : (textColor ?? node.foregroundColor ?? theme.colors.onSurface)
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
        let renderCache = engine.cachedRenderLayout(node: node,
                                env: env,
                                displayText: renderState.displayText,
                                measurementText: renderState.measurementText,
                                font: resolvedFont,
                                lineHeight: resolvedLineHeight,
                                availableTextWidth: max(0, frameWidth - insetX * 2 - addonLeading - addonTrailing))
        // Reserve trailing-edge real estate for clear icon + counter so the
        // text/caret never collide with the affordances. Both the visual draw
        // and the hit-test rely on this same reservation.
        let showClear = clearable && !disabled && !readOnly && !current.isEmpty && isFocused
        let counterText: String?
        if showWordLimit, let maxLength {
            counterText = "\(current.count)/\(maxLength)"
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
        if let prepend, !prepend.isEmpty {
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
        if let append, !append.isEmpty {
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
        if let prefix, !prefix.isEmpty {
            let prependWidth: Float = {
                guard let prepend, !prepend.isEmpty else { return 0 }
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
        if let suffix, !suffix.isEmpty {
            let appendWidth: Float = {
                guard let append, !append.isEmpty else { return 0 }
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
                                 visibleTopY: state.scrollOffsetY,
                                 visibleBottomY: state.scrollOffsetY + state.visibleTextHeight,
                                 list: list,
                                 color: resolvedSelectionColor.multipliedAlpha(node.opacity))
        }

        let visibleLayout = engine.visibleLayout(from: renderCache.layout,
                                                 scrollOffsetY: state.scrollOffsetY,
                                                 visibleHeight: state.visibleTextHeight,
                                                 lineHeight: resolvedLineHeight)
        if showsLineNumbers && axis == .vertical {
            drawLineNumbers(visibleLayout,
                            source: current,
                            origin: origin,
                            textOriginX: textOriginX,
                            textOriginY: textOriginY,
                            frameHeight: frameHeight,
                            lineHeight: resolvedLineHeight,
                            node: node,
                            env: env,
                            font: resolvedFont,
                            list: list)
        }

        list.addText(visibleLayout,
                     origin: (textOriginX, textOriginY),
                     color: renderColor,
                     textureID: env.atlasTextureID,
                     atlas: env.atlas,
                     colorForGlyph: { glyph in
            guard !renderState.showsPlaceholder,
                  !renderState.isComposing,
                  let syntaxColor = syntaxColorAtUTF8Offset?(current, Int(glyph.cluster)) else {
                return nil
            }
            return syntaxColor.multipliedAlpha(node.opacity)
        })

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
            state.clearHitX = clearX
            drawClearGlyph(at: clearX,
                           y: textOriginY,
                           size: glyphSize,
                           list: list,
                           color: resolvedPlaceholderColor.multipliedAlpha(node.opacity))
        } else {
            state.clearHitX = nil
        }

        if isFocused, let compositionRange = renderState.compositionRange {
            engine.drawUnderline(compositionRange,
                                 in: renderState.measurementText,
                                 env: env,
                                 font: resolvedFont,
                                 lineHeight: resolvedLineHeight,
                                 layout: renderCache.layout,
                                 textOriginX: textOriginX,
                                 textOriginY: textOriginY,
                                 visibleTopY: state.scrollOffsetY,
                                 visibleBottomY: state.scrollOffsetY + state.visibleTextHeight,
                                 list: list,
                                 color: resolvedCursorColor.multipliedAlpha(node.opacity * 0.8))
        }

        let caret = viewport.rawCaret
        let caretX = textOriginX + caret.x
        let caretY = textOriginY + caret.topY

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
        state.lastDrawOrigin = absoluteOrigin
        guard let env = TextEnvironmentHolder.current else { return nil }

        let current = text.wrappedValue
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
        let renderState = layoutEngine.makeRenderState(current: current,
                                                       state: state,
                                                       isFocused: isFocused)
        let renderCache = layoutEngine.cachedRenderLayout(node: node,
                                                          env: env,
                                                          displayText: renderState.displayText,
                                                          measurementText: renderState.measurementText,
                                                          font: resolvedFont,
                                                          lineHeight: resolvedLineHeight,
                                                          availableTextWidth: max(0,
                                                                                  frameWidth
                                                                                  - insetX * 2
                                                                                  - addonLeading
                                                                                  - addonTrailing))
        let viewport = layoutEngine.updateViewport(node: node,
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
        let renderState = layoutEngine.makeRenderState(current: current,
                                                       state: state,
                                                       isFocused: isFocused)
        let renderCache = layoutEngine.cachedRenderLayout(node: node,
                                                          env: env,
                                                          displayText: renderState.displayText,
                                                          measurementText: renderState.measurementText,
                                                          font: resolvedFont,
                                                          lineHeight: resolvedLineHeight,
                                                          availableTextWidth: max(0,
                                                                                  Float(node.frame.width)
                                                                                  - insetX * 2
                                                                                  - addonLeading
                                                                                  - addonTrailing))
        layoutEngine.refreshScrollMetrics(node: node,
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
    /// writes the result back to `state.cursorIndex`.
    private func positionCursor(atWindowPoint point: CGPoint,
                                state: FieldState,
                                node: Node) {
        state.cursorIndex = layoutEngine.characterIndex(atWindowPoint: point, state: state, node: node)
    }

    /// Map a window-space point to a character index.
    /// Treats glyph index as character index — accurate for ASCII; ligatures,
    /// CJK, and emoji are still approximate.
    func characterIndex(atWindowPoint point: CGPoint,
                        state: FieldState,
                        node: Node) -> Int {
        layoutEngine.characterIndex(atWindowPoint: point, state: state, node: node)
    }

    private func moveCursorVertically(lineDelta: Int,
                                      extendSelection: Bool,
                                      state: FieldState,
                                      node: Node) {
        guard lineDelta != 0 else { return }
        let engine = layoutEngine
        guard let env = TextEnvironmentHolder.current else {
            moveCursor(to: state.cursorIndex, extendSelection: extendSelection, state: state)
            return
        }

        let current = text.wrappedValue
        let resolvedFont = resolvedFont(node: node, env: env)
        let resolvedLineHeight = resolvedLineHeight(node: node, env: env)
        let layout = engine.interactiveLayout(in: current,
                                              node: node,
                                              env: env,
                                              font: resolvedFont,
                                              lineHeight: resolvedLineHeight)
        let ranges = engine.lineRanges(in: current, layout: layout)
        guard !ranges.isEmpty else {
            moveCursor(to: 0, extendSelection: extendSelection, state: state)
            return
        }
        let cursorIndex = clamp(state.cursorIndex, 0, current.count)
        let currentLineIndex = engine.lineIndex(for: cursorIndex, lineRanges: ranges)
        let targetLineIndex = clamp(currentLineIndex + lineDelta, 0, max(0, ranges.count - 1))
        guard targetLineIndex != currentLineIndex else {
            let currentCaret = engine.caretLocation(in: current,
                                                    cursorIndex: cursorIndex,
                                                    env: env,
                                                    font: resolvedFont,
                                                    lineHeight: resolvedLineHeight,
                                                    layout: layout)
            moveCursor(to: cursorIndex,
                       extendSelection: extendSelection,
                       state: state,
                       preferredCaretX: state.preferredCaretX ?? currentCaret.x)
            return
        }

        let currentCaret = engine.caretLocation(in: current,
                                                cursorIndex: cursorIndex,
                                                env: env,
                                                font: resolvedFont,
                                                lineHeight: resolvedLineHeight,
                                                layout: layout)
        let desiredX = state.preferredCaretX ?? currentCaret.x
        let targetRange = ranges[targetLineIndex]
        let targetLineText = substring(current, targetRange)
        let targetColumn = engine.characterIndex(inLineText: targetLineText,
                                                 desiredX: desiredX,
                                                 env: env,
                                                 font: resolvedFont)
        moveCursor(to: targetRange.lowerBound + targetColumn,
                   extendSelection: extendSelection,
                   state: state,
                   preferredCaretX: desiredX)
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
            state.selectionAnchor = 0
            state.cursorIndex = text.wrappedValue.count
            state.isDragging = false
        case 2:
            // Double click: select the word under the cursor.
            let target = characterIndex(atWindowPoint: CGPoint(x: CGFloat(event.x),
                                                               y: CGFloat(event.y)),
                                        state: state,
                                        node: node)
            let (lo, hi) = wordBounds(in: text.wrappedValue, around: target)
            state.selectionAnchor = lo
            state.cursorIndex = hi
            state.isDragging = false
        default:
            // Single click: place the cursor and start a drag selection.
            state.selectionAnchor = nil
            positionCursor(atWindowPoint: CGPoint(x: CGFloat(event.x),
                                                  y: CGFloat(event.y)),
                           state: state,
                           node: node)
            state.isDragging = true
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
        if let prepend, !prepend.isEmpty {
            let layout = env.cachedLayout(text: prepend, font: font, lineHeight: lineHeight,
                                          maxWidth: .infinity, alignment: .leading)
            // Slab paddings (left + right) are theme.spacing.sm on each side.
            width += layout.totalWidth + horizontalInset(theme: theme) * 2 + theme.spacing.sm
        }
        if let prefix, !prefix.isEmpty {
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
        guard showsLineNumbers, axis == .vertical else { return 0 }
        let lineCount = max(1, text.wrappedValue.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        })
        let numberFont = Font.system(size: max(9, font.size - 2))
        let numberLayout = env.cachedLayout(text: String(repeating: "8", count: String(lineCount).count),
                                            font: numberFont,
                                            lineHeight: lineHeight,
                                            maxWidth: .infinity,
                                            alignment: .trailing)
        return numberLayout.totalWidth + theme.spacing.md
    }

    private func drawLineNumbers(_ layout: TextLayoutResult,
                                 source: String,
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
                     color: (lineNumberGutterColor ?? theme.colors.surfaceVariant)
                        .multipliedAlpha(node.opacity))
        list.addRect(UIRect(x: textOriginX - 1,
                            y: Float(origin.y),
                            width: 1,
                            height: frameHeight),
                     color: theme.colors.onSurfaceMuted.multipliedAlpha(node.opacity * 0.22))

        let numberFont = Font.system(size: max(9, font.size - 2))
        let utf8 = Array(source.utf8)
        var lastLineNumber = 0
        for line in layout.lines {
            let byteOffset = min(utf8.count, Int(line.startCluster))
            let lineNumber = 1 + utf8[..<byteOffset].reduce(into: 0) { count, byte in
                if byte == 10 { count += 1 }
            }
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
                         color: (lineNumberColor ?? theme.colors.onSurfaceMuted)
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
        if let suffix, !suffix.isEmpty {
            let layout = env.cachedLayout(text: suffix, font: font, lineHeight: lineHeight,
                                          maxWidth: .infinity, alignment: .leading)
            width += layout.totalWidth + theme.spacing.xs
        }
        if let append, !append.isEmpty {
            let layout = env.cachedLayout(text: append, font: font, lineHeight: lineHeight,
                                          maxWidth: .infinity, alignment: .leading)
            width += layout.totalWidth + horizontalInset(theme: theme) * 2 + theme.spacing.sm
        }
        return width
    }

    func textOriginYOffset(frameHeight: Float, lineHeight: Float) -> Float {
        if axis == .vertical {
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
        guard snapshot.axis == .vertical else {
            layout.setMeasureFunc(nil)
            return
        }

        layout.setMeasureFunc { [weak layout] width, widthMode, _, _ in
            guard let env = TextEnvironmentHolder.current else {
                return CGSize(width: 0, height: CGFloat(snapshot.minimumFieldHeight))
            }
            let fontOverride = layout?.attachments[StyleAttachmentKey.font] as? Font
            let lineHeightOverride = layout?.attachments[StyleAttachmentKey.lineHeight] as? Float
            let resolvedFont = env.resolvedFont(fontOverride)
            let resolvedLineHeight = env.resolvedLineHeight(font: resolvedFont,
                                                            override: lineHeightOverride)
            let measureText = snapshot.text.wrappedValue.isEmpty
                ? snapshot.placeholder
                : snapshot.displayValue(snapshot.text.wrappedValue)
            let wrapWidth: Float
            switch widthMode {
            case .exactly, .atMost:
                wrapWidth = max(1, width - 16)
            case .undefined:
                wrapWidth = .infinity
            }
            let layoutResult: TextLayoutResult
            if measureText.isEmpty {
                layoutResult = env.cachedLayout(
                    text: "",
                    font: resolvedFont,
                    lineHeight: resolvedLineHeight,
                    maxWidth: wrapWidth,
                    alignment: .leading
                )
            } else {
                layoutResult = Text.cachedLayout(
                    env: env,
                    layout: layout,
                    text: measureText,
                    font: resolvedFont,
                    lineHeight: resolvedLineHeight,
                    maxWidth: wrapWidth,
                    alignment: .leading
                )
            }

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
                                resolvedLineHeight * Float(snapshot.maxVisibleLines) + insetY * 2)

            return CGSize(width: CGFloat(resolvedWidth),
                          height: CGFloat(min(max(snapshot.minimumFieldHeight,
                                                  contentHeight + insetY * 2),
                                              maxHeight)))
        }
    }

    private func resolvedFieldHeight(layout: LayoutNode?) -> Float {
        guard axis != .vertical else {
            return minimumFieldHeight
        }
        let measureText = text.wrappedValue.isEmpty
            ? placeholder
            : displayValue(text.wrappedValue)
        let lineCount = max(1, layoutEngine.lineRanges(in: measureText).count)
        guard axis == .vertical || lineCount > 1 else {
            return minimumFieldHeight
        }
        guard let env = TextEnvironmentHolder.current else {
            return minimumFieldHeight
        }

        let fontOverride = layout?.attachments[StyleAttachmentKey.font] as? Font
        let lineHeightOverride = layout?.attachments[StyleAttachmentKey.lineHeight] as? Float
        let resolvedFont = env.resolvedFont(fontOverride)
        let resolvedLineHeight = env.resolvedLineHeight(font: resolvedFont,
                                                        override: lineHeightOverride)
        let insetY = Self.verticalInset(for: resolvedLineHeight)
        let contentHeight = Float(lineCount) * resolvedLineHeight
        let maxHeight = max(minimumFieldHeight,
                            resolvedLineHeight * Float(maxVisibleLines) + insetY * 2)
        return min(max(minimumFieldHeight, contentHeight + insetY * 2), maxHeight)
    }

    func resolvedFont(node: Node, env: TextEnvironment) -> Font {
        env.resolvedFont(node.attachments[StyleAttachmentKey.font] as? Font)
    }

    func resolvedLineHeight(node: Node, env: TextEnvironment) -> Float {
        env.resolvedLineHeight(
            font: resolvedFont(node: node, env: env),
            override: node.attachments[StyleAttachmentKey.lineHeight] as? Float
        )
    }

    func displayValue(_ value: String) -> String {
        secure ? String(repeating: "•", count: value.count) : value
    }

    /// Find the word covering `index` in `s`. A "word" is a maximal run of
    /// characters whose `wordKind` matches; clicks on a non-word character
    /// (whitespace / punctuation) select the run of the same kind.
    private func wordBounds(in s: String, around index: Int) -> (Int, Int) {
        let chars = Array(s)
        guard !chars.isEmpty else { return (0, 0) }
        let i = clamp(index, 0, chars.count - 1)
        let kind = wordKind(chars[i])
        var lo = i
        while lo > 0 && wordKind(chars[lo - 1]) == kind { lo -= 1 }
        var hi = i + 1
        while hi < chars.count && wordKind(chars[hi]) == kind { hi += 1 }
        return (lo, hi)
    }

    private enum CharKind { case word, space, other }
    private func wordKind(_ c: Character) -> CharKind {
        if c.isLetter || c.isNumber || c == "_" { return .word }
        if c.isWhitespace { return .space }
        return .other
    }

    /// Option+Left / Option+Backspace target: skip any whitespace immediately
    /// before the caret, then the run of same-kind characters before it.
    func wordBoundaryBefore(in s: String, offset: Int) -> Int {
        let chars = Array(s)
        var i = clamp(offset, 0, chars.count)
        while i > 0 && wordKind(chars[i - 1]) == .space { i -= 1 }
        guard i > 0 else { return 0 }
        let kind = wordKind(chars[i - 1])
        while i > 0 && wordKind(chars[i - 1]) == kind { i -= 1 }
        return i
    }

    /// Option+Right target: skip whitespace at the caret, then the run of
    /// same-kind characters after it.
    func wordBoundaryAfter(in s: String, offset: Int) -> Int {
        let chars = Array(s)
        var i = clamp(offset, 0, chars.count)
        while i < chars.count && wordKind(chars[i]) == .space { i += 1 }
        guard i < chars.count else { return chars.count }
        let kind = wordKind(chars[i])
        while i < chars.count && wordKind(chars[i]) == kind { i += 1 }
        return i
    }
}

@inline(__always)
func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
    min(max(v, lo), hi)
}
