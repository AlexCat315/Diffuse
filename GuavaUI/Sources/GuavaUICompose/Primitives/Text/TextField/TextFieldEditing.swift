#if canImport(CoreGraphics)
import CoreGraphics
#endif
import EngineKernel
import GuavaUIRuntime

extension TextField {
    /// Session state belongs to the surface node and survives reconciliation.
    /// Each group describes one independent editing responsibility.
    final class FieldState {
        weak var hostNode: Node?
        var buffer = TextBuffer.empty
        var selection = SelectionState()
        var composition = CompositionState()
        var scroll = ScrollState()
        var pointer = PointerState()
        var transaction = TransactionState()
        var renderDraft = RenderDraftState()
        var lastCaretActivity = TimingTrace.now()

        func clearComposition() { composition = CompositionState() }
    }

    struct SelectionState {
        var cursorIndex = 0
        var anchor: Int?
        var preferredCaretX: Float?
        var lineEndAffinity = false
    }

    struct CompositionState {
        var text = ""
        var start = 0
        var length = 0
        var isActive: Bool { !text.isEmpty }
    }

    struct RenderDraftState {
        var placeholder = ""
        var placeholderBuffer = TextBuffer.empty
        var preview: CompositionPreview?
    }
    struct CompositionPreview {
        let source: TextBuffer
        let range: Range<Int>
        let text: String
        let buffer: TextBuffer
    }

    struct ScrollState {
        var horizontal = HorizontalScrollState()
        var offsetY: Float = 0
        var maxY: Float = 0
        var visibleHeight: Float = 0
        var contentHeight: Float = 0
        var needsCaretReveal = false
    }

    struct PointerState {
        var lastDrawOrigin: CGPoint = .zero
        var isDragging = false
        var clearHitX: Float?
    }

    struct TransactionState {
        var history = TextEditHistory()
        var depth = 0
        var before: TextEditHistory.Snapshot?
        var kind: TextEditHistory.Kind = .atomic
    }

    /// Clamp persisted indices into the current text. `FieldState` outlives
    /// recompose while the bound text can be rewritten underneath it (entity
    /// switch, formatter, programmatic set); a stale `cursorIndex` past the
    /// new end must never reach `String.index(_:offsetBy:)` math.
    func normalizeIndices(_ state: FieldState) {
        if state.buffer != text.wrappedValue { state.selection.lineEndAffinity = false }
        state.buffer = text.wrappedValue
        let count = state.buffer.characterCount
        state.selection.cursorIndex = clamp(state.selection.cursorIndex, 0, count)
        if let anchor = state.selection.anchor {
            let bounded = clamp(anchor, 0, count)
            state.selection.anchor = bounded == state.selection.cursorIndex ? nil : bounded
        }
    }

    /// Returns the active selection range as a half-open `[low, high)` in
    /// `Character` units, or nil when there is no selection. Bounds are
    /// clamped to the current text so stale state can't index out of range.
    func selectionRange(_ state: FieldState) -> Range<Int>? {
        guard let anchor = state.selection.anchor, anchor != state.selection.cursorIndex else { return nil }
        let count = text.wrappedValue.characterCount
        let lower = clamp(min(anchor, state.selection.cursorIndex), 0, count)
        let upper = clamp(max(anchor, state.selection.cursorIndex), 0, count)
        guard lower != upper else { return nil }
        return lower..<upper
    }

    func substring(_ text: TextBuffer, _ range: Range<Int>) -> String {
        text.substring(characterRange: range)
    }

    /// Delete the active selection (if any). Returns true when a selection
    /// was deleted; the caller should then skip its own delete-one logic.
    @discardableResult
    func deleteSelection(state: FieldState) -> Bool {
        beginEdit(state, kind: .deletion)
        defer { endEdit(state) }
        guard let range = selectionRange(state) else { return false }
        let startByte = text.wrappedValue.utf8Offset(forCharacterIndex: range.lowerBound)
        let currentText = text.wrappedValue.delete(characterRange: range)
        text.wrappedValue = currentText
        state.selection.cursorIndex = currentText.characterIndex(forUTF8Offset: startByte)
        state.selection.anchor = nil
        state.selection.preferredCaretX = nil
        recordCaretActivity(state)
        events.onChange?(currentText)
        return true
    }

    /// Replace the active selection with `incoming`, or insert at the cursor
    /// when no selection exists. Both paths leave the cursor at the end of
    /// the inserted text and clear any selection.
    func insertReplacingSelection(_ incoming: String, state: FieldState) {
        let selection = selectionRange(state)
        let typing = incoming.count == 1 && incoming != "\n" && selection == nil && !state.composition.isActive
        beginEdit(state, kind: typing ? .typing : .atomic)
        defer { endEdit(state) }
        guard !incoming.isEmpty else { return }
        let previous = text.wrappedValue
        let cursor = selection?.lowerBound ?? clamp(state.selection.cursorIndex, 0, previous.characterCount)
        let removed = selection?.count ?? 0
        let capacity = behavior.maxLength.map { max(0, $0 - (previous.characterCount - removed)) }
        let insertion = capacity.map { String(incoming.prefix($0)) } ?? incoming
        guard !insertion.isEmpty else { return }
        let startByte = previous.utf8Offset(forCharacterIndex: cursor)
        let currentText = previous.replace(characterRange: cursor..<(cursor + removed), with: insertion)
        state.clearComposition()
        text.wrappedValue = currentText
        // Inserting a combining scalar or regional indicator can join adjacent
        // graphemes. The inserted byte endpoint remains the correct caret.
        state.selection.cursorIndex = currentText.characterIndex(forUTF8Offset: startByte + insertion.utf8.count)
        state.selection.anchor = nil
        state.selection.preferredCaretX = nil
        recordCaretActivity(state)
        events.onChange?(currentText)
    }

    /// Empty the field, fire `onClear`, and reset selection/cursor state.
    /// Invoked by both the trailing-edge clear icon and external callers.
    func performClear(state: FieldState) {
        beginEdit(state, kind: .atomic)
        defer { endEdit(state) }
        guard !text.wrappedValue.isEmpty else { return }
        text.wrappedValue = ""
        state.selection.cursorIndex = 0
        state.selection.anchor = nil
        state.selection.preferredCaretX = nil
        state.clearComposition()
        recordCaretActivity(state)
        events.onClear?()
        events.onChange?("")
    }

    /// Move the cursor to `target`. When `extendSelection` is true an anchor
    /// is established (if missing) so the move grows / shrinks a selection;
    /// otherwise any existing selection is collapsed.
    func moveCursor(to target: Int, extendSelection: Bool, state: FieldState) {
        let count = text.wrappedValue.characterCount
        let bounded = clamp(target, 0, count)
        if extendSelection {
            if state.selection.anchor == nil {
                state.selection.anchor = state.selection.cursorIndex
            }
        } else {
            state.selection.anchor = nil
        }
        state.selection.cursorIndex = bounded
        state.selection.preferredCaretX = nil
        recordCaretActivity(state)
    }

    func moveCursor(to target: Int,
                    extendSelection: Bool,
                    state: FieldState,
                    preferredCaretX: Float?) {
        let count = text.wrappedValue.characterCount
        let bounded = clamp(target, 0, count)
        if extendSelection {
            if state.selection.anchor == nil {
                state.selection.anchor = state.selection.cursorIndex
            }
        } else {
            state.selection.anchor = nil
        }
        state.selection.cursorIndex = bounded
        state.selection.preferredCaretX = preferredCaretX
        recordCaretActivity(state)
    }

    /// Every caret/selection mutation funnels through here: reset the blink
    /// phase and invalidate the field's cached render layer so the change is
    /// visible on the very next frame (frames may be event-driven).
    func recordCaretActivity(_ state: FieldState) {
        state.selection.lineEndAffinity = false
        state.buffer = text.wrappedValue
        if let node = state.hostNode { updateAccessibilityValue(on: node, buffer: state.buffer) }
        state.scroll.needsCaretReveal = true
        state.lastCaretActivity = TimingTrace.now()
        state.hostNode?.markRenderDirty(reason: .styleSet(field: "textFieldCaret"))
        notifyCaretChange(state)
        state.hostNode?.firstResource(TextCompletionSession.self)?.activity()
    }
}
