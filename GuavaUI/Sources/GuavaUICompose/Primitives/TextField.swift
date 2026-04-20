import CoreGraphics
import EngineKernel
import GuavaUIRuntime

/// Single-line text input. Routes IME / printable text through the
/// `textInput` handler, and routes editing keys (backspace, delete, arrows,
/// home/end, shift-extension, Cmd/Ctrl-A/C/V/X) through the `key` handler.
/// Auto-focuses on click.
///
/// v1 limitations:
/// - Single line only (Enter fires `onSubmit` but is otherwise ignored).
/// - Selection is keyboard-driven; mouse drag is Phase 6.4e.
/// - State (cursor index, selection anchor, scroll offset) lives in a
///   captured reference and is lost on recompose; an explicit `@State`
///   cursor is a Phase 6.6 task.
/// - Reads from `TextEnvironment` for shaping; without one installed the
///   field still accepts input but renders no glyphs.
public struct TextField: _PrimitiveView {

    public let text: Binding<String>
    public let placeholder: String
    public let onSubmit: (() -> Void)?
    public let textColor: Color?
    public let placeholderColor: Color
    public let cursorColor: Color
    public let selectionColor: Color

    public init(_ placeholder: String = "",
                text: Binding<String>,
                onSubmit: (() -> Void)? = nil,
                textColor: Color? = nil,
                placeholderColor: Color = Color(r: 0.55, g: 0.55, b: 0.6),
                cursorColor: Color = Color.white,
                selectionColor: Color = Color(r: 0.30, g: 0.55, b: 0.95, a: 0.45)) {
        self.text = text
        self.placeholder = placeholder
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
    }

    public func _makeNode() -> Node {
        let n = Node()
        n.isHitTestable = true
        n.isFocusable = true
        return n
    }

    public func _updateNode(_ node: Node) {
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
                let target = snapshot.characterIndex(atWindowX: event.x, state: state)
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
        layout.height = 28
        return layout
    }

    public func _updateLayout(_ layout: LayoutNode) {
        layout.height = 28
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
        return true
    }

    /// Replace the active selection with `incoming`, or insert at the cursor
    /// when no selection exists. Both paths leave the cursor at the end of
    /// the inserted text and clear any selection.
    private func insertReplacingSelection(_ incoming: String, state: FieldState) {
        guard !incoming.isEmpty else { return }
        deleteSelection(state: state)
        var s = text.wrappedValue
        let cursor = clamp(state.cursorIndex, 0, s.count)
        let at = s.index(s.startIndex, offsetBy: cursor)
        s.insert(contentsOf: incoming, at: at)
        text.wrappedValue = s
        state.cursorIndex = cursor + incoming.count
        state.selectionAnchor = nil
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
            }
            return true
        case 76: // DELETE
            if !deleteSelection(state: state) {
                guard state.cursorIndex < count else { return true }
                var s = text.wrappedValue
                let removeAt = s.index(s.startIndex, offsetBy: state.cursorIndex)
                s.remove(at: removeAt)
                text.wrappedValue = s
            }
            return true
        case 80: // LEFT
            if !shift, let r = selectionRange(state) {
                state.selectionAnchor = nil
                state.cursorIndex = r.lowerBound
            } else {
                moveCursor(to: state.cursorIndex - 1, extendSelection: shift, state: state)
            }
            return true
        case 79: // RIGHT
            if !shift, let r = selectionRange(state) {
                state.selectionAnchor = nil
                state.cursorIndex = r.upperBound
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
            onSubmit?()
            return true
        default:
            return false
        }
    }

    // MARK: - Render

    private func render(node: Node, state: FieldState, list: DrawList, origin: CGPoint) {
        state.lastDrawOrigin = origin
        guard let env = TextEnvironmentHolder.current else { return }
        let isFocused = (FocusChainHolder.current?.focused === node)
        let current = text.wrappedValue
        let displayText = current.isEmpty ? placeholder : current
        let renderColor: Color =
            current.isEmpty
                ? placeholderColor
                : (textColor ?? node.foregroundColor ?? env.defaultColor)

        // Selection highlight first (drawn under the glyphs).
        if isFocused, let range = selectionRange(state), !current.isEmpty {
            let xLo = cursorX(in: current, upTo: range.lowerBound, env: env)
            let xHi = cursorX(in: current, upTo: range.upperBound, env: env)
            list.addRect(
                UIRect(x: Float(origin.x) + xLo,
                       y: Float(origin.y),
                       width: max(1, xHi - xLo),
                       height: env.defaultLineHeight),
                color: selectionColor
            )
        }

        let glyphs = env.shaper.shape(text: displayText)
        let result = TextLayout.layout(
            shapedGlyphs: glyphs,
            text: displayText,
            atlas: env.atlas,
            maxWidth: .infinity,
            lineHeight: env.defaultLineHeight,
            alignment: .leading
        )
        list.addText(result,
                     origin: (Float(origin.x), Float(origin.y)),
                     color: renderColor,
                     textureID: env.atlasTextureID)

        // Cursor — suppressed while a non-empty selection is active.
        guard isFocused, selectionRange(state) == nil else { return }
        let cursorXValue = cursorX(in: current,
                                   upTo: clamp(state.cursorIndex, 0, current.count),
                                   env: env)
        let cursorRect = UIRect(
            x: Float(origin.x) + cursorXValue,
            y: Float(origin.y),
            width: 1,
            height: env.defaultLineHeight
        )
        list.addRect(cursorRect, color: cursorColor)
    }

    /// Width of `text` shaped from index 0 up to `count` characters. Used to
    /// place the cursor and selection edges. Re-shapes each frame; v1
    /// simplicity over caching.
    private func cursorX(in text: String, upTo count: Int, env: TextEnvironment) -> Float {
        guard count > 0 else { return 0 }
        let endIdx = text.index(text.startIndex, offsetBy: count)
        let prefix = String(text[text.startIndex..<endIdx])
        let glyphs = env.shaper.shape(text: prefix)
        let layout = TextLayout.layout(
            shapedGlyphs: glyphs,
            text: prefix,
            atlas: env.atlas,
            maxWidth: .infinity,
            lineHeight: env.defaultLineHeight,
            alignment: .leading
        )
        return layout.totalWidth
    }

    /// Snap the cursor to the character boundary nearest a window-space x.
    /// Convenience wrapper around `characterIndex(atWindowX:)` that also
    /// writes the result back to `state.cursorIndex`.
    private func positionCursor(atWindowX windowX: Float, state: FieldState) {
        state.cursorIndex = characterIndex(atWindowX: windowX, state: state)
    }

    /// Map a window-space x coordinate to a character index.
    /// Walks shaped glyph advances and picks the side of the midline. Treats
    /// glyph index as character index — accurate for ASCII; ligatures, CJK,
    /// and emoji are still approximate.
    private func characterIndex(atWindowX windowX: Float, state: FieldState) -> Int {
        let current = text.wrappedValue
        guard !current.isEmpty, let env = TextEnvironmentHolder.current else {
            return 0
        }
        let localX = windowX - Float(state.lastDrawOrigin.x)
        if localX <= 0 { return 0 }
        let glyphs = env.shaper.shape(text: current)
        var pen: Float = 0
        for (i, g) in glyphs.enumerated() {
            let mid = pen + g.xAdvance * 0.5
            if localX < mid { return i }
            pen += g.xAdvance
        }
        return min(glyphs.count, current.count)
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
            // Triple click: select the entire (single-line) field.
            state.selectionAnchor = 0
            state.cursorIndex = text.wrappedValue.count
            state.isDragging = false
        case 2:
            // Double click: select the word under the cursor.
            let target = characterIndex(atWindowX: event.x, state: state)
            let (lo, hi) = wordBounds(in: text.wrappedValue, around: target)
            state.selectionAnchor = lo
            state.cursorIndex = hi
            state.isDragging = false
        default:
            // Single click: place the cursor and start a drag selection.
            state.selectionAnchor = nil
            positionCursor(atWindowX: event.x, state: state)
            state.isDragging = true
            PointerCaptureHolder.current?.acquire(node)
        }
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
