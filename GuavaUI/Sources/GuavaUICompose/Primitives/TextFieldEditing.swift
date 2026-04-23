import CoreGraphics
import EngineKernel
import GuavaUIRuntime

extension TextField {
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

        func clearComposition() {
            compositionText = ""
            compositionStart = 0
            compositionLength = 0
        }

        var isComposing: Bool { !compositionText.isEmpty }
    }

    /// Returns the active selection range as a half-open `[low, high)` in
    /// `Character` units, or nil when there is no selection.
    func selectionRange(_ state: FieldState) -> Range<Int>? {
        guard let anchor = state.selectionAnchor, anchor != state.cursorIndex else { return nil }
        return min(anchor, state.cursorIndex)..<max(anchor, state.cursorIndex)
    }

    func substring(_ text: String, _ range: Range<Int>) -> String {
        let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
        let upper = text.index(text.startIndex, offsetBy: range.upperBound)
        return String(text[lower..<upper])
    }

    /// Delete the active selection (if any). Returns true when a selection
    /// was deleted; the caller should then skip its own delete-one logic.
    @discardableResult
    func deleteSelection(state: FieldState) -> Bool {
        guard let range = selectionRange(state) else { return false }
        var currentText = text.wrappedValue
        let lower = currentText.index(currentText.startIndex, offsetBy: range.lowerBound)
        let upper = currentText.index(currentText.startIndex, offsetBy: range.upperBound)
        currentText.removeSubrange(lower..<upper)
        text.wrappedValue = currentText
        state.cursorIndex = range.lowerBound
        state.selectionAnchor = nil
        state.preferredCaretX = nil
        recordCaretActivity(state)
        onChange?(currentText)
        return true
    }

    /// Replace the active selection with `incoming`, or insert at the cursor
    /// when no selection exists. Both paths leave the cursor at the end of
    /// the inserted text and clear any selection.
    func insertReplacingSelection(_ incoming: String, state: FieldState) {
        guard !incoming.isEmpty else { return }
        state.clearComposition()
        deleteSelection(state: state)
        var currentText = text.wrappedValue
        let cursor = clamp(state.cursorIndex, 0, currentText.count)
        let toInsert: String
        if let maxLength {
            let remaining = max(0, maxLength - currentText.count)
            guard remaining > 0 else { return }
            toInsert = incoming.count > remaining ? String(incoming.prefix(remaining)) : incoming
        } else {
            toInsert = incoming
        }
        let insertionIndex = currentText.index(currentText.startIndex, offsetBy: cursor)
        currentText.insert(contentsOf: toInsert, at: insertionIndex)
        text.wrappedValue = currentText
        state.cursorIndex = cursor + toInsert.count
        state.selectionAnchor = nil
        state.preferredCaretX = nil
        recordCaretActivity(state)
        onChange?(currentText)
    }

    /// Empty the field, fire `onClear`, and reset selection/cursor state.
    /// Invoked by both the trailing-edge clear icon and external callers.
    func performClear(state: FieldState) {
        guard !text.wrappedValue.isEmpty else { return }
        text.wrappedValue = ""
        state.cursorIndex = 0
        state.selectionAnchor = nil
        state.preferredCaretX = nil
        state.clearComposition()
        recordCaretActivity(state)
        onClear?()
        onChange?("")
    }

    /// Move the cursor to `target`. When `extendSelection` is true an anchor
    /// is established (if missing) so the move grows / shrinks a selection;
    /// otherwise any existing selection is collapsed.
    func moveCursor(to target: Int, extendSelection: Bool, state: FieldState) {
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

    func recordCaretActivity(_ state: FieldState) {
        state.lastCaretActivity = TimingTrace.now()
    }
}