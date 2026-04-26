import CoreGraphics
import EngineKernel
import GuavaUIRuntime

/// Text input field. The default horizontal axis is single-line; the
/// vertical axis accepts explicit newline insertion and grows in height to fit
/// those lines.
///
/// v1 limitations:
/// - State (cursor index, selection anchor, scroll offset) lives in a
///   captured reference and is lost on recompose; an explicit `@State`
///   cursor is a Phase 6.6 task.
/// - Reads from `TextEnvironment` for shaping; without one installed the
///   field still accepts input but renders no glyphs.
public struct TextField: View {

    public enum Axis: Sendable {
        case horizontal
        case vertical
    }

    /// Visual size variants matching Element Plus Input semantics.
    /// Drives field height, horizontal padding, and font metrics.
    public enum Size: Sendable {
        case large
        case regular
        case small
    }

    public let text: Binding<String>
    public let placeholder: String
    public let axis: Axis
    public let size: Size
    public let disabled: Bool
    public let readOnly: Bool
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
    public let onSubmit: (() -> Void)?
    public let onChange: ((String) -> Void)?
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
                size: Size = .regular,
                disabled: Bool = false,
                readOnly: Bool = false,
                clearable: Bool = false,
                maxLength: Int? = nil,
                showWordLimit: Bool = false,
                prefix: String? = nil,
                suffix: String? = nil,
                prepend: String? = nil,
                append: String? = nil,
                onSubmit: (() -> Void)? = nil,
                onChange: ((String) -> Void)? = nil,
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
        self.size = size
        self.disabled = disabled
        self.readOnly = readOnly
        self.clearable = clearable
        self.maxLength = maxLength
        self.showWordLimit = showWordLimit
        self.prefix = prefix
        self.suffix = suffix
        self.prepend = prepend
        self.append = append
        self.onSubmit = onSubmit
        self.onChange = onChange
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
    }

    private static let minimumFieldHeightDefault: Float = 32
    private static let multilineMaxVisibleLines: Float = 6
    static let multilineWheelStep: Float = 30
    static let scrollbarTrackThickness: Float = 6
    static let scrollbarInset: Float = 3
    private var minimumFieldHeight: Float {
        switch size {
        case .large:   return 40
        case .regular: return 32
        case .small:   return 24
        }
    }
    /// Optional intrinsic font size override applied per `Size` so an
    /// unstyled TextField still picks up a smaller body in the `.small`
    /// variant. Returning `nil` keeps the active TextEnvironment default.
    private var sizeFontSize: Float? {
        switch size {
        case .large:   return 14
        case .regular: return 14
        case .small:   return 12
        }
    }
    private static let caretBlinkHalfPeriod: Double = 0.5
    private static let caretBlinkSteadyDuration: Double = 0.5
    private static let measureInputsKey = "__textfield_measure_inputs"
    static let scrollbarHoveredKey = "__textfield_scrollbar_hovered"
    static let scrollbarChromeOpacityKey = "__textfield_scrollbar_chrome_opacity"
    static let surfaceMarkerKey = "__textfield_surface"
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
        let snapshot = self

        updateInteractionHandlers(for: node, state: state)
        node.attachments[WheelRoutingAttachmentKey.priority] = interactionState.isFocused
            ? WheelRoutingPriority.preferFocused
            : nil
        node.attachments[TextInputAttachmentKey.focusChangeHandler] = { [weak node] focused in
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

        node.draw = { list, origin in
            snapshot.render(node: node,
                            state: state,
                            list: list,
                            origin: origin,
                            interactionState: interactionState)
        }
        node.overlayDraw = { [weak node] list, origin in
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
                                   axis: axis)
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
                                 axis: axis)
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
        let mods = event.modifiers
        let shift = !mods.isDisjoint(with: .shift)
        let cmdOrCtrl = !mods.isDisjoint(with: .gui) || !mods.isDisjoint(with: .ctrl)
        let count = text.wrappedValue.count
        // In read-only mode the field still accepts caret motion, selection,
        // and Cmd+A / Cmd+C so users can copy the value, but every mutation
        // (typing, paste, cut, backspace, delete, newline insert) is silently
        // dropped — matching Element Plus' readonly Input behaviour.
        let blockMutations = readOnly

        // Cmd/Ctrl shortcuts take priority over plain bindings.
        if cmdOrCtrl {
            switch event.scancode {
            case 4:  // A
                state.selectionAnchor = 0
                state.cursorIndex = count
                recordCaretActivity(state)
                return true
            case 6:  // C
                if let r = selectionRange(state) {
                    ClipboardHolder.write?(substring(text.wrappedValue, r))
                }
                return true
            case 25: // V
                guard !blockMutations else { return true }
                if let s = ClipboardHolder.read?(), !s.isEmpty {
                    insertReplacingSelection(s, state: state)
                }
                return true
            case 27: // X
                guard !blockMutations else { return true }
                if let r = selectionRange(state) {
                    ClipboardHolder.write?(substring(text.wrappedValue, r))
                    deleteSelection(state: state)
                }
                return true
            default:
                break
            }
        }

        switch event.scancode {
        case 42: // BACKSPACE
            guard !blockMutations else { return true }
            if !deleteSelection(state: state) {
                guard state.cursorIndex > 0 else { return true }
                var s = text.wrappedValue
                let removeAt = s.index(s.startIndex, offsetBy: state.cursorIndex - 1)
                s.remove(at: removeAt)
                text.wrappedValue = s
                state.cursorIndex -= 1
                recordCaretActivity(state)
                onChange?(s)
            }
            return true
        case 76: // DELETE
            guard !blockMutations else { return true }
            if !deleteSelection(state: state) {
                guard state.cursorIndex < count else { return true }
                var s = text.wrappedValue
                let removeAt = s.index(s.startIndex, offsetBy: state.cursorIndex)
                s.remove(at: removeAt)
                text.wrappedValue = s
                recordCaretActivity(state)
                onChange?(s)
            }
            return true
        case 80: // LEFT
            if !shift, let r = selectionRange(state) {
                state.selectionAnchor = nil
                state.cursorIndex = r.lowerBound
                recordCaretActivity(state)
            } else {
                moveCursor(to: state.cursorIndex - 1, extendSelection: shift, state: state)
            }
            return true
        case 79: // RIGHT
            if !shift, let r = selectionRange(state) {
                state.selectionAnchor = nil
                state.cursorIndex = r.upperBound
                recordCaretActivity(state)
            } else {
                moveCursor(to: state.cursorIndex + 1, extendSelection: shift, state: state)
            }
            return true
        case 74: // HOME
            moveCursor(to: 0, extendSelection: shift, state: state)
            return true
        case 77: // END
            moveCursor(to: count, extendSelection: shift, state: state)
            return true
        case 82: // UP
            moveCursorVertically(lineDelta: -1, extendSelection: shift, state: state, node: node)
            return true
        case 81: // DOWN
            moveCursorVertically(lineDelta: 1, extendSelection: shift, state: state, node: node)
            return true
        case 40, 88: // RETURN, KP_ENTER
            if !cmdOrCtrl, !blockMutations, (axis == .vertical || shift) {
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

        list.addText(engine.visibleLayout(from: renderCache.layout,
                                          scrollOffsetY: state.scrollOffsetY,
                                          visibleHeight: state.visibleTextHeight,
                                          lineHeight: resolvedLineHeight),
                     origin: (textOriginX, textOriginY),
                     color: renderColor,
                     textureID: env.atlasTextureID,
                     atlas: env.atlas)

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
        return width
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

    /// Render a small "✕" affordance at `(x, y)` using the active text
    /// environment so the glyph stays consistent with the input typography.
    /// Falls back silently when no environment is available.
    private func drawClearGlyph(at x: Float,
                                y: Float,
                                size: Float,
                                list: DrawList,
                                color: Color) {
        guard let env = TextEnvironmentHolder.current else { return }
        let glyphFont = Font.system(size: size * 0.75)
        let layout = env.cachedLayout(text: "✕",
                                      font: glyphFont,
                                      lineHeight: size,
                                      maxWidth: .infinity,
                                      alignment: .leading)
        // Centre the glyph horizontally inside its reserved square so the
        // visual matches Element Plus' suffix-icon padding.
        let glyphX = x + max(0, (size - layout.totalWidth) * 0.5)
        list.addText(layout,
                     origin: (glyphX, y),
                     color: color,
                     textureID: env.atlasTextureID,
                     atlas: env.atlas)
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
                : snapshot.text.wrappedValue
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
                                resolvedLineHeight * Self.multilineMaxVisibleLines + insetY * 2)

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
        let measureText = text.wrappedValue.isEmpty ? placeholder : text.wrappedValue
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
                            resolvedLineHeight * Self.multilineMaxVisibleLines + insetY * 2)
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
}

@inline(__always)
func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
    min(max(v, lo), hi)
}
