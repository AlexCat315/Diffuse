import CoreGraphics
import EngineKernel
import GuavaUIRuntime

/// Text input field. The default horizontal axis is single-line; the
/// vertical axis accepts explicit newline insertion and grows in height to fit
/// those lines.
///
/// v1 limitations:
/// - Vertical mode handles explicit newlines, but does not soft-wrap long
///   lines to the field width yet.
/// - State (cursor index, selection anchor, scroll offset) lives in a
///   captured reference and is lost on recompose; an explicit `@State`
///   cursor is a Phase 6.6 task.
/// - Reads from `TextEnvironment` for shaping; without one installed the
///   field still accepts input but renders no glyphs.
public struct TextField: _PrimitiveView {

    public enum Axis: Sendable {
        case horizontal
        case vertical
    }

    public let text: Binding<String>
    public let placeholder: String
    public let axis: Axis
    public let onSubmit: (() -> Void)?
    public let textColor: Color?
    public let placeholderColor: Color?
    public let cursorColor: Color?
    public let selectionColor: Color?

    public init(_ placeholder: String = "",
                text: Binding<String>,
        axis: Axis = .horizontal,
                onSubmit: (() -> Void)? = nil,
                textColor: Color? = nil,
                placeholderColor: Color? = nil,
                cursorColor: Color? = nil,
                selectionColor: Color? = nil) {
        self.text = text
        self.placeholder = placeholder
    self.axis = axis
        self.onSubmit = onSubmit
        self.textColor = textColor
        self.placeholderColor = placeholderColor
        self.cursorColor = cursorColor
        self.selectionColor = selectionColor
    }

    /// Per-instance editing state. Lives on the captured closures so it
    /// persists across redraws without recompose.
    final class FieldState {
        /// Cursor index measured in `Character` units from the start of `text`.
        var cursorIndex: Int = 0
        /// Selection anchor in `Character` units; `nil` means no selection.
        /// When non-nil, the live selection is `[min(anchor, cursor), max)`.
        var selectionAnchor: Int? = nil
        /// Absolute window-space origin captured during the last render pass;
        /// used to translate pointer events into local coordinates.
        var lastDrawOrigin: CGPoint = .zero
        /// True between pointer-down and pointer-up while a drag is active.
        /// Motion events extend the selection only when this is set.
        var isDragging: Bool = false
        /// Active IME preedit string. It is rendered into the field but is not
        /// committed into `text` until the platform sends `textInput`.
        var compositionText: String = ""
        var compositionStart: Int = 0
        var compositionLength: Int = 0
        var lastCaretActivity: Double = TimingTrace.now()

        func clearComposition() {
            compositionText = ""
            compositionStart = 0
            compositionLength = 0
        }

        var isComposing: Bool { !compositionText.isEmpty }
    }

    private struct RenderState {
        let displayText: String
        let measurementText: String
        let cursorIndex: Int
        let compositionRange: Range<Int>?
        let showsPlaceholder: Bool
        let isComposing: Bool
    }

    private struct RenderCacheKey: Equatable {
        let displayText: String
        let measurementText: String
        let font: Font
        let lineHeight: Float
        let atlasID: ObjectIdentifier
    }

    private struct MeasureInputs: Equatable {
        let text: String
        let placeholder: String
        let axis: Axis
    }

    private final class RenderCacheEntry {
        let key: RenderCacheKey
        let layout: TextLayoutResult

        init(key: RenderCacheKey,
             layout: TextLayoutResult) {
            self.key = key
            self.layout = layout
        }
    }

    private struct CaretLocation {
        let x: Float
        let topY: Float
    }

    private static let minimumFieldHeight: Float = 32
    private static let caretBlinkHalfPeriod: Double = 0.5
    private static let caretBlinkSteadyDuration: Double = 0.5
    private static let measureCacheKey = "__textfield_measure_cache"
    private static let measureInputsKey = "__textfield_measure_inputs"

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.isFocusable = true
        n.clipsToBounds = true
        return n
    }

    public func _updateNode(_ node: Node) {
        // Keep the primitive fallback aligned with the public default style so
        // freshly-created fields still look like recessed editor inputs even
        // before higher-level style modifiers wrap them.
        let theme = node.theme
        node.backgroundColor = theme.colors.surfaceSunken
        node.cornerRadius = theme.radius.sm
        node.cursor = .ibeam

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

        if let registry = InteractionRegistryHolder.current {
            registry.setEditing(node) { event, _ in
                state.compositionText = event.text
                let compositionCount = event.text.count
                state.compositionStart = clamp(Int(event.start), 0, compositionCount)
                state.compositionLength = clamp(Int(event.length), 0, max(0, compositionCount - state.compositionStart))
                snapshot.recordCaretActivity(state)
                return .handled
            }
            registry.setText(node) { incoming, _ in
                snapshot.insertReplacingSelection(incoming, state: state)
                return .handled
            }
            registry.setKey(node) { event, _ in
                snapshot.handleKey(event, state: state) ? .handled : .ignored
            }
            registry.setPointer(node) { event, phase, _ in
                switch phase {
                case .down:
                    snapshot.handlePointerDown(event: event, state: state, node: node)
                    return .handled
                case .up:
                    state.isDragging = false
                    PointerCaptureHolder.current?.release()
                    return .handled
                }
            }
            registry.setMotion(node) { event, _ in
                guard state.isDragging else { return .ignored }
                let target = snapshot.characterIndex(atWindowPoint: CGPoint(x: CGFloat(event.x),
                                                                            y: CGFloat(event.y)),
                                                     state: state,
                                                     node: node)
                if state.selectionAnchor == nil {
                    state.selectionAnchor = state.cursorIndex
                }
                state.cursorIndex = target
                return .handled
            }
        }

        node.draw = { list, origin in
            snapshot.render(node: node, state: state, list: list, origin: origin)
        }
    }

    public func _makeLayoutNode() -> LayoutNode? {
        let layout = LayoutNode()
        Self.installMeasureFunc(on: layout, snapshot: self)
        let inputs = MeasureInputs(text: text.wrappedValue,
                                   placeholder: placeholder,
                                   axis: axis)
        layout.attachments[Self.measureInputsKey] = inputs
        if axis == .horizontal {
            layout.height = Self.minimumFieldHeight
        }
        return layout
    }

    public func _updateLayout(_ layout: LayoutNode) {
        Self.installMeasureFunc(on: layout, snapshot: self)
        let next = MeasureInputs(text: text.wrappedValue,
                                 placeholder: placeholder,
                                 axis: axis)
        let previous = layout.attachments[Self.measureInputsKey] as? MeasureInputs
        layout.attachments[Self.measureInputsKey] = next
        if axis == .horizontal {
            layout.height = Self.minimumFieldHeight
        } else {
            layout.height = nil
            if previous != nil, previous != next {
                layout.markDirty()
            }
        }
    }

    // MARK: - Selection helpers

    /// Returns the active selection range as a half-open `[low, high)` in
    /// `Character` units, or nil when there is no selection.
    private func selectionRange(_ state: FieldState) -> Range<Int>? {
        guard let a = state.selectionAnchor, a != state.cursorIndex else { return nil }
        return min(a, state.cursorIndex)..<max(a, state.cursorIndex)
    }

    private func substring(_ s: String, _ range: Range<Int>) -> String {
        let lo = s.index(s.startIndex, offsetBy: range.lowerBound)
        let hi = s.index(s.startIndex, offsetBy: range.upperBound)
        return String(s[lo..<hi])
    }

    /// Delete the active selection (if any). Returns true when a selection
    /// was deleted; the caller should then skip its own delete-one logic.
    @discardableResult
    private func deleteSelection(state: FieldState) -> Bool {
        guard let range = selectionRange(state) else { return false }
        var s = text.wrappedValue
        let lo = s.index(s.startIndex, offsetBy: range.lowerBound)
        let hi = s.index(s.startIndex, offsetBy: range.upperBound)
        s.removeSubrange(lo..<hi)
        text.wrappedValue = s
        state.cursorIndex = range.lowerBound
        state.selectionAnchor = nil
        recordCaretActivity(state)
        return true
    }

    /// Replace the active selection with `incoming`, or insert at the cursor
    /// when no selection exists. Both paths leave the cursor at the end of
    /// the inserted text and clear any selection.
    private func insertReplacingSelection(_ incoming: String, state: FieldState) {
        guard !incoming.isEmpty else { return }
        state.clearComposition()
        deleteSelection(state: state)
        var s = text.wrappedValue
        let cursor = clamp(state.cursorIndex, 0, s.count)
        let at = s.index(s.startIndex, offsetBy: cursor)
        s.insert(contentsOf: incoming, at: at)
        text.wrappedValue = s
        state.cursorIndex = cursor + incoming.count
        state.selectionAnchor = nil
        recordCaretActivity(state)
    }

    /// Move the cursor to `target`. When `extendSelection` is true an anchor
    /// is established (if missing) so the move grows / shrinks a selection;
    /// otherwise any existing selection is collapsed.
    private func moveCursor(to target: Int, extendSelection: Bool, state: FieldState) {
        let count = text.wrappedValue.count
        let bounded = clamp(target, 0, count)
        if extendSelection {
            if state.selectionAnchor == nil {
                state.selectionAnchor = state.cursorIndex
            }
        } else {
            state.selectionAnchor = nil
        }
        state.cursorIndex = bounded
        recordCaretActivity(state)
    }

    private func recordCaretActivity(_ state: FieldState) {
        state.lastCaretActivity = TimingTrace.now()
    }

    // MARK: - Editing

    private func handleKey(_ event: KeyEvent, state: FieldState) -> Bool {
        let mods = event.modifiers
        let shift = !mods.isDisjoint(with: .shift)
        let cmdOrCtrl = !mods.isDisjoint(with: .gui) || !mods.isDisjoint(with: .ctrl)
        let count = text.wrappedValue.count

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
                if let s = ClipboardHolder.read?(), !s.isEmpty {
                    insertReplacingSelection(s, state: state)
                }
                return true
            case 27: // X
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
            if !deleteSelection(state: state) {
                guard state.cursorIndex > 0 else { return true }
                var s = text.wrappedValue
                let removeAt = s.index(s.startIndex, offsetBy: state.cursorIndex - 1)
                s.remove(at: removeAt)
                text.wrappedValue = s
                state.cursorIndex -= 1
                recordCaretActivity(state)
            }
            return true
        case 76: // DELETE
            if !deleteSelection(state: state) {
                guard state.cursorIndex < count else { return true }
                var s = text.wrappedValue
                let removeAt = s.index(s.startIndex, offsetBy: state.cursorIndex)
                s.remove(at: removeAt)
                text.wrappedValue = s
                recordCaretActivity(state)
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
        case 40, 88: // RETURN, KP_ENTER
            if axis == .vertical, !cmdOrCtrl {
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

    private func render(node: Node, state: FieldState, list: DrawList, origin: CGPoint) {
        state.lastDrawOrigin = origin
        guard let env = TextEnvironmentHolder.current else { return }
        let theme = node.theme
        let isFocused = (FocusChainHolder.current?.focused === node)
        if !isFocused, state.isComposing {
            state.clearComposition()
        }
        let current = text.wrappedValue
        let resolvedFont = resolvedFont(node: node, env: env)
        let resolvedLineHeight = resolvedLineHeight(node: node, env: env)
        let resolvedPlaceholderColor = placeholderColor ?? theme.colors.onSurfaceMuted
        let resolvedCursorColor = cursorColor ?? theme.colors.onSurface
        let resolvedSelectionColor = selectionColor ?? theme.colors.selection
        let renderState = makeRenderState(current: current, state: state, isFocused: isFocused)
        let renderBaseColor: Color =
            renderState.showsPlaceholder
                ? resolvedPlaceholderColor
                : (textColor ?? node.foregroundColor ?? env.defaultColor)
        let renderColor = renderBaseColor.multipliedAlpha(node.opacity)
        let renderCache = cachedRenderLayout(node: node,
                                             env: env,
                                             displayText: renderState.displayText,
                                             measurementText: renderState.measurementText,
                                             font: resolvedFont,
                                             lineHeight: resolvedLineHeight)

        let insetX = horizontalInset(theme: theme)
        let textOriginX = Float(origin.x) + insetX
        let frameHeight = Float(node.frame.height)
        let textOriginY = Float(origin.y) + textOriginYOffset(frameHeight: frameHeight,
                                                              lineHeight: resolvedLineHeight)

        // Selection highlight first (drawn under the glyphs).
        if isFocused, !renderState.isComposing, let range = selectionRange(state), !current.isEmpty {
            drawSelection(range,
                          in: current,
                          env: env,
                          font: resolvedFont,
                          lineHeight: resolvedLineHeight,
                          textOriginX: textOriginX,
                          textOriginY: textOriginY,
                          list: list,
                          color: resolvedSelectionColor.multipliedAlpha(node.opacity))
        }

        list.addText(renderCache.layout,
                     origin: (textOriginX, textOriginY),
                     color: renderColor,
                     textureID: env.atlasTextureID,
                     atlas: env.atlas)

        if isFocused, let compositionRange = renderState.compositionRange {
            drawUnderline(compositionRange,
                          in: renderState.measurementText,
                          env: env,
                          font: resolvedFont,
                          lineHeight: resolvedLineHeight,
                          textOriginX: textOriginX,
                          textOriginY: textOriginY,
                          list: list,
                          color: resolvedCursorColor.multipliedAlpha(node.opacity * 0.8))
        }

        let caret = caretLocation(in: renderState.measurementText,
                                  cursorIndex: clamp(renderState.cursorIndex, 0, renderState.measurementText.count),
                                  env: env,
                                  font: resolvedFont,
                                  lineHeight: resolvedLineHeight)
        let caretHeight = resolvedLineHeight
        let caretX = textOriginX + caret.x
        let caretY = textOriginY + caret.topY
        node.attachments[TextInputAttachmentKey.area] = TextInputArea(
            x: caretX,
            y: caretY,
            width: max(1, resolvedLineHeight),
            height: caretHeight,
            cursorX: 0
        )

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

    private func cachedRenderLayout(node: Node,
                                    env: TextEnvironment,
                                    displayText: String,
                                    measurementText: String,
                                    font: Font,
                                    lineHeight: Float) -> RenderCacheEntry {
        let key = RenderCacheKey(displayText: displayText,
                                 measurementText: measurementText,
                                 font: font,
                                 lineHeight: lineHeight,
                                 atlasID: ObjectIdentifier(env.atlas))
        if let cached = node.attachments["__textfield_render_cache"] as? RenderCacheEntry,
           cached.key == key {
            return cached
        }
        let layout = env.cachedLayout(
            text: displayText,
            font: font,
            lineHeight: lineHeight,
            maxWidth: .infinity,
            alignment: .leading
        )
        let entry = RenderCacheEntry(key: key, layout: layout)
        node.attachments["__textfield_render_cache"] = entry
        return entry
    }

    private func makeRenderState(current: String,
                                 state: FieldState,
                                 isFocused: Bool) -> RenderState {
        guard isFocused, state.isComposing else {
            if current.isEmpty {
                return RenderState(
                    displayText: placeholder,
                    measurementText: "",
                    cursorIndex: 0,
                    compositionRange: nil,
                    showsPlaceholder: true,
                    isComposing: false
                )
            }
            return RenderState(
                displayText: current,
                measurementText: current,
                cursorIndex: clamp(state.cursorIndex, 0, current.count),
                compositionRange: nil,
                showsPlaceholder: false,
                isComposing: false
            )
        }

        let replaceRange = selectionRange(state) ?? (state.cursorIndex..<state.cursorIndex)
        var preview = current
        let lo = preview.index(preview.startIndex, offsetBy: replaceRange.lowerBound)
        let hi = preview.index(preview.startIndex, offsetBy: replaceRange.upperBound)
        preview.replaceSubrange(lo..<hi, with: state.compositionText)

        let compositionStart = replaceRange.lowerBound
        let compositionEnd = compositionStart + state.compositionText.count
        let cursorOffset = state.compositionLength > 0
            ? state.compositionStart + state.compositionLength
            : state.compositionText.count

        return RenderState(
            displayText: preview,
            measurementText: preview,
            cursorIndex: compositionStart + clamp(cursorOffset, 0, state.compositionText.count),
            compositionRange: compositionStart..<compositionEnd,
            showsPlaceholder: false,
            isComposing: true
        )
    }

    /// Snap the cursor to the character boundary nearest a window-space point.
    /// Convenience wrapper around `characterIndex(atWindowX:)` that also
    /// writes the result back to `state.cursorIndex`.
    private func positionCursor(atWindowPoint point: CGPoint,
                                state: FieldState,
                                node: Node) {
        state.cursorIndex = characterIndex(atWindowPoint: point, state: state, node: node)
    }

    /// Map a window-space point to a character index.
    /// Treats glyph index as character index — accurate for ASCII; ligatures,
    /// CJK, and emoji are still approximate.
    private func characterIndex(atWindowPoint point: CGPoint,
                                state: FieldState,
                                node: Node) -> Int {
        guard let env = TextEnvironmentHolder.current else {
            return 0
        }
        let current = text.wrappedValue
        let lineRanges = self.lineRanges(in: current)
        guard !lineRanges.isEmpty else {
            return 0
        }

        let resolvedFont = resolvedFont(node: node, env: env)
        let lineHeight = resolvedLineHeight(node: node, env: env)
        let localX = Float(point.x) - Float(state.lastDrawOrigin.x) - horizontalInset(theme: node.theme)
        let localY = Float(point.y) - Float(state.lastDrawOrigin.y) - textOriginYOffset(frameHeight: Float(node.frame.height),
                                                  lineHeight: lineHeight)

        let lineIndex = clamp(Int((max(localY, 0) / max(lineHeight, 1)).rounded(.down)),
                              0,
                              max(0, lineRanges.count - 1))
        let lineRange = lineRanges[lineIndex]
        let lineText = substring(current, lineRange)
        if localX <= 0 {
            return lineRange.lowerBound
        }

        let glyphs = env.shape(text: lineText, font: resolvedFont)
        var pen: Float = 0
        for (index, glyph) in glyphs.enumerated() {
            let mid = pen + glyph.xAdvance * 0.5
            if localX < mid {
                return lineRange.lowerBound + index
            }
            pen += glyph.xAdvance
        }
        return lineRange.upperBound
    }

    // MARK: - Pointer / multi-click

    /// Handle a pointer-down event: dispatch to single-click cursor placement,
    /// double-click word selection, or triple-click select-all based on
    /// `event.clicks` (set by SDL3 to 1 / 2 / 3 for the click cadence).
    private func handlePointerDown(event: MouseButtonEvent,
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

    private func horizontalInset(theme: Theme) -> Float {
        max(4, theme.spacing.sm)
    }

    private func textOriginYOffset(frameHeight: Float, lineHeight: Float) -> Float {
        if axis == .vertical {
            return Self.verticalInset(for: lineHeight)
        }
        return max(0, (frameHeight - lineHeight) / 2)
    }

    private static func verticalInset(for lineHeight: Float) -> Float {
        max(4, (minimumFieldHeight - lineHeight) * 0.5)
    }

    private func lineRanges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for (index, character) in text.enumerated() {
            if character == "\n" {
                ranges.append(start..<index)
                start = index + 1
            }
        }
        ranges.append(start..<text.count)
        return ranges.isEmpty ? [0..<0] : ranges
    }

    private func lineIndex(for cursorIndex: Int, lineRanges: [Range<Int>]) -> Int {
        for (index, range) in lineRanges.enumerated() {
            if cursorIndex <= range.upperBound {
                return index
            }
        }
        return max(0, lineRanges.count - 1)
    }

    private func rangeLength(_ range: Range<Int>) -> Int {
        range.upperBound - range.lowerBound
    }

    private func linePrefixWidth(in text: String,
                                 upTo count: Int,
                                 env: TextEnvironment,
                                 font: Font,
                                 lineHeight: Float) -> Float {
        let bounded = clamp(count, 0, text.count)
        guard bounded > 0 else { return 0 }
        let endIndex = text.index(text.startIndex, offsetBy: bounded)
        let prefix = String(text[text.startIndex..<endIndex])
        let layout = env.cachedLayout(
            text: prefix,
            font: font,
            lineHeight: lineHeight,
            maxWidth: .infinity,
            alignment: .leading
        )
        return layout.lines.last?.width ?? 0
    }

    private func caretLocation(in text: String,
                               cursorIndex: Int,
                               env: TextEnvironment,
                               font: Font,
                               lineHeight: Float) -> CaretLocation {
        let ranges = lineRanges(in: text)
        let line = lineIndex(for: clamp(cursorIndex, 0, text.count), lineRanges: ranges)
        let range = ranges[line]
        let column = clamp(cursorIndex - range.lowerBound, 0, rangeLength(range))
        let lineText = substring(text, range)
        return CaretLocation(
            x: linePrefixWidth(in: lineText,
                               upTo: column,
                               env: env,
                               font: font,
                               lineHeight: lineHeight),
            topY: Float(line) * lineHeight
        )
    }

    private func drawSelection(_ range: Range<Int>,
                               in text: String,
                               env: TextEnvironment,
                               font: Font,
                               lineHeight: Float,
                               textOriginX: Float,
                               textOriginY: Float,
                               list: DrawList,
                               color: Color) {
        let ranges = lineRanges(in: text)
        let startLine = lineIndex(for: range.lowerBound, lineRanges: ranges)
        let endLine = lineIndex(for: range.upperBound, lineRanges: ranges)
        for line in startLine...endLine {
            let lineRange = ranges[line]
            let lower = max(range.lowerBound, lineRange.lowerBound)
            let upper = min(range.upperBound, lineRange.upperBound)
            guard upper > lower else { continue }
            let lineText = substring(text, lineRange)
            let xLo = linePrefixWidth(in: lineText,
                                      upTo: lower - lineRange.lowerBound,
                                      env: env,
                                      font: font,
                                      lineHeight: lineHeight)
            let xHi = linePrefixWidth(in: lineText,
                                      upTo: upper - lineRange.lowerBound,
                                      env: env,
                                      font: font,
                                      lineHeight: lineHeight)
            list.addRect(
                UIRect(x: textOriginX + xLo,
                       y: textOriginY + Float(line) * lineHeight,
                       width: max(1, xHi - xLo),
                       height: lineHeight),
                color: color
            )
        }
    }

    private func drawUnderline(_ range: Range<Int>,
                               in text: String,
                               env: TextEnvironment,
                               font: Font,
                               lineHeight: Float,
                               textOriginX: Float,
                               textOriginY: Float,
                               list: DrawList,
                               color: Color) {
        let ranges = lineRanges(in: text)
        let startLine = lineIndex(for: range.lowerBound, lineRanges: ranges)
        let endLine = lineIndex(for: range.upperBound, lineRanges: ranges)
        for line in startLine...endLine {
            let lineRange = ranges[line]
            let lower = max(range.lowerBound, lineRange.lowerBound)
            let upper = min(range.upperBound, lineRange.upperBound)
            guard upper > lower else { continue }
            let lineText = substring(text, lineRange)
            let xLo = linePrefixWidth(in: lineText,
                                      upTo: lower - lineRange.lowerBound,
                                      env: env,
                                      font: font,
                                      lineHeight: lineHeight)
            let xHi = linePrefixWidth(in: lineText,
                                      upTo: upper - lineRange.lowerBound,
                                      env: env,
                                      font: font,
                                      lineHeight: lineHeight)
            list.addRect(
                UIRect(x: textOriginX + xLo,
                       y: textOriginY + Float(line) * lineHeight + lineHeight - 1,
                       width: max(1, xHi - xLo),
                       height: 1),
                color: color
            )
        }
    }

    private static func installMeasureFunc(on layout: LayoutNode, snapshot: TextField) {
        guard snapshot.axis == .vertical else {
            layout.setMeasureFunc(nil)
            return
        }

        layout.setMeasureFunc { [weak layout] width, widthMode, _, _ in
            guard let env = TextEnvironmentHolder.current else {
                return CGSize(width: 0, height: CGFloat(minimumFieldHeight))
            }
            let fontOverride = layout?.attachments[StyleAttachmentKey.font] as? Font
            let lineHeightOverride = layout?.attachments[StyleAttachmentKey.lineHeight] as? Float
            let resolvedFont = env.resolvedFont(fontOverride)
            let resolvedLineHeight = env.resolvedLineHeight(font: resolvedFont,
                                                            override: lineHeightOverride)
            let measureText = snapshot.text.wrappedValue.isEmpty
                ? snapshot.placeholder
                : snapshot.text.wrappedValue
            let layoutResult: TextLayoutResult
            if measureText.isEmpty {
                layoutResult = env.cachedLayout(
                    text: "",
                    font: resolvedFont,
                    lineHeight: resolvedLineHeight,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            } else {
                layoutResult = Text.cachedLayout(
                    env: env,
                    attachments: { layout?.attachments[measureCacheKey] },
                    store: { layout?.attachments[measureCacheKey] = $0 },
                    text: measureText,
                    font: resolvedFont,
                    lineHeight: resolvedLineHeight,
                    maxWidth: .infinity,
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

            return CGSize(width: CGFloat(resolvedWidth),
                          height: CGFloat(max(minimumFieldHeight,
                                              contentHeight + insetY * 2)))
        }
    }

    private func resolvedFont(node: Node, env: TextEnvironment) -> Font {
        env.resolvedFont(node.attachments[StyleAttachmentKey.font] as? Font)
    }

    private func resolvedLineHeight(node: Node, env: TextEnvironment) -> Float {
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
private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
    min(max(v, lo), hi)
}
