#if canImport(CoreGraphics)
import CoreGraphics
#endif
import EngineKernel
import GuavaUIRuntime

extension TextField {
    /// Per-instance editing state. Lives on the captured closures so it
    /// persists across redraws without recompose.
    final class FieldState {
        /// Surface node owning this state. Caret/selection changes happen
        /// outside recompose, so they must invalidate the node's cached layer
        /// themselves (`LayerAwareNodeRenderer` replays clean layers verbatim).
        weak var hostNode: Node?
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
        /// Last x of the trailing-edge clear button hit-target (in window
        /// coordinates), captured during render. `nil` means no clear icon
        /// is currently drawn.
        var clearHitX: Float? = nil
        /// Preserved horizontal caret target when moving across lines.
        var preferredCaretX: Float? = nil
        /// Vertical scroll offset for overflowing multiline content.
        var scrollOffsetY: Float = 0
        /// Cached max vertical scroll after the last render.
        var maxScrollY: Float = 0
        /// Visible text viewport height after chrome insets.
        var visibleTextHeight: Float = 0
        /// Total laid-out content height from the last render.
        var contentHeight: Float = 0

        struct EditSnapshot {
            let text: String
            let cursor: Int
            let anchor: Int?
        }
        var undoHistory: [EditSnapshot] = []
        var redoHistory: [EditSnapshot] = []
        var lastKnownText: String?
        var lastInsertionTime: Double = 0
        var lastInsertionCursor: Int? = nil

        func breakUndoGroup() { lastInsertionCursor = nil }

        func clearComposition() {
            compositionText = ""
            compositionStart = 0
            compositionLength = 0
        }

        var isComposing: Bool { !compositionText.isEmpty }
    }

    /// Clamp persisted indices into the current text. `FieldState` outlives
    /// recompose while the bound text can be rewritten underneath it (entity
    /// switch, formatter, programmatic set); a stale `cursorIndex` past the
    /// new end must never reach `String.index(_:offsetBy:)` math.
    func normalizeIndices(_ state: FieldState) {
        let count = text.wrappedValue.count
        state.cursorIndex = clamp(state.cursorIndex, 0, count)
        if let anchor = state.selectionAnchor {
            let bounded = clamp(anchor, 0, count)
            state.selectionAnchor = bounded == state.cursorIndex ? nil : bounded
        }
    }

    /// Returns the active selection range as a half-open `[low, high)` in
    /// `Character` units, or nil when there is no selection. Bounds are
    /// clamped to the current text so stale state can't index out of range.
    func selectionRange(_ state: FieldState) -> Range<Int>? {
        guard let anchor = state.selectionAnchor, anchor != state.cursorIndex else { return nil }
        let count = text.wrappedValue.count
        let lower = clamp(min(anchor, state.cursorIndex), 0, count)
        let upper = clamp(max(anchor, state.cursorIndex), 0, count)
        guard lower != upper else { return nil }
        return lower..<upper
    }

    func substring(_ text: String, _ range: Range<Int>) -> String {
        let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
        let upper = text.index(text.startIndex, offsetBy: range.upperBound)
        return String(text[lower..<upper])
    }

    func synchronizeHistory(_ state: FieldState) {
        if let previous = state.lastKnownText, previous != text.wrappedValue {
            state.undoHistory.removeAll()
            state.redoHistory.removeAll()
            state.breakUndoGroup()
        }
        state.lastKnownText = text.wrappedValue
    }

    func applyEdit(_ next: String, cursor: Int, state: FieldState, coalesceInsertion: Bool = false) {
        synchronizeHistory(state)
        let current = text.wrappedValue
        guard next != current else { return }
        let now = TimingTrace.now()
        let merge = coalesceInsertion && state.selectionAnchor == nil
            && state.lastInsertionCursor == state.cursorIndex
            && now - state.lastInsertionTime < 0.75
        if !merge {
            state.undoHistory.append(.init(text: current, cursor: state.cursorIndex, anchor: state.selectionAnchor))
            if state.undoHistory.count > 100 { state.undoHistory.removeFirst() }
        }
        state.redoHistory.removeAll()
        text.wrappedValue = next
        state.lastKnownText = text.wrappedValue
        state.cursorIndex = cursor
        state.selectionAnchor = nil
        state.preferredCaretX = nil
        state.clearComposition()
        state.lastInsertionTime = now
        state.lastInsertionCursor = coalesceInsertion ? cursor : nil
        recordCaretActivity(state)
        onChange?(next)
    }

    func restoreEdit(state: FieldState, redo: Bool) {
        synchronizeHistory(state)
        state.breakUndoGroup()
        let snapshot = redo ? state.redoHistory.popLast() : state.undoHistory.popLast()
        guard let snapshot else { return }
        let current = FieldState.EditSnapshot(text: text.wrappedValue, cursor: state.cursorIndex, anchor: state.selectionAnchor)
        if redo { state.undoHistory.append(current) } else { state.redoHistory.append(current) }
        text.wrappedValue = snapshot.text
        state.lastKnownText = text.wrappedValue
        state.cursorIndex = snapshot.cursor
        state.selectionAnchor = snapshot.anchor
        state.preferredCaretX = nil
        state.clearComposition()
        normalizeIndices(state)
        recordCaretActivity(state)
        onChange?(snapshot.text)
    }

    @discardableResult
    func deleteSelection(state: FieldState) -> Bool {
        guard let range = selectionRange(state) else { return false }
        var current = text.wrappedValue
        let lower = current.index(current.startIndex, offsetBy: range.lowerBound)
        let upper = current.index(current.startIndex, offsetBy: range.upperBound)
        current.removeSubrange(lower..<upper)
        applyEdit(current, cursor: range.lowerBound, state: state)
        return true
    }

    /// Replacing a selection is one transaction, including paste and IME commits.
    func insertReplacingSelection(_ incoming: String, state: FieldState) {
        guard !incoming.isEmpty else { return }
        normalizeIndices(state)
        var current = text.wrappedValue
        let range = selectionRange(state)
        let cursor = range?.lowerBound ?? state.cursorIndex
        if let range {
            let lower = current.index(current.startIndex, offsetBy: range.lowerBound)
            let upper = current.index(current.startIndex, offsetBy: range.upperBound)
            current.removeSubrange(lower..<upper)
        }
        let remaining = maxLength.map { max(0, $0 - current.count) } ?? incoming.count
        let insertion = String(incoming.prefix(remaining))
        guard !insertion.isEmpty else { return }
        current.insert(contentsOf: insertion, at: current.index(current.startIndex, offsetBy: cursor))
        applyEdit(current, cursor: cursor + insertion.count, state: state,
                  coalesceInsertion: range == nil && !state.isComposing && insertion.count == 1 && insertion != "\n")
    }

    func performClear(state: FieldState) {
        guard !text.wrappedValue.isEmpty else { return }
        applyEdit("", cursor: 0, state: state)
        onClear?()
    }

    /// Move the cursor to `target`. When `extendSelection` is true an anchor
    /// is established (if missing) so the move grows / shrinks a selection;
    /// otherwise any existing selection is collapsed.
    func moveCursor(to target: Int, extendSelection: Bool, state: FieldState) {
        state.breakUndoGroup()
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
        state.preferredCaretX = nil
        recordCaretActivity(state)
    }

    func moveCursor(to target: Int,
                    extendSelection: Bool,
                    state: FieldState,
                    preferredCaretX: Float?) {
        state.breakUndoGroup()
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
        state.preferredCaretX = preferredCaretX
        recordCaretActivity(state)
    }

    /// Every caret/selection mutation funnels through here: reset the blink
    /// phase and invalidate the field's cached render layer so the change is
    /// visible on the very next frame (frames may be event-driven).
    func recordCaretActivity(_ state: FieldState) {
        state.lastCaretActivity = TimingTrace.now()
        state.hostNode?.markRenderDirty(reason: .styleSet(field: "textFieldCaret"))
        notifyCaretChange(state)
    }
}
