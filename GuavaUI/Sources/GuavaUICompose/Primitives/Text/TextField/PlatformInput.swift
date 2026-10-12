import GuavaUIRuntime

extension TextField {
    func platformInputClient(_ state: FieldState) -> TextInputClient {
        func options(_ value: TextInputClient.Snapshot) -> TextInputClient.Snapshot {
            var result = value
            result.isSecure = behavior.secure; result.isReadOnly = behavior.readOnly
            result.isMultiline = layout.axis == .vertical
            return result
        }
        func offset(_ character: Int) -> Int {
            text.wrappedValue.substring(characterRange: 0..<character).utf16.count
        }
        func character(_ offset: Int, roundUp: Bool = false) -> Int {
            var units = 0
            for (index, glyph) in text.wrappedValue.stringValue.enumerated() {
                let next = units + String(glyph).utf16.count
                if offset < next { return roundUp && offset > units ? index + 1 : index }
                units = next
            }
            return text.wrappedValue.characterCount
        }
        return TextInputClient(snapshot: {
            normalizeIndices(state)
            let range = selectionRange(state) ?? state.selection.cursorIndex..<state.selection.cursorIndex
            let start = offset(range.lowerBound), end = offset(range.upperBound)
            guard state.composition.isActive else {
                return options(.init(text: text.wrappedValue.stringValue, selectionStart: start, selectionEnd: end))
            }
            let preview = text.wrappedValue.replace(characterRange: range, with: state.composition.text).stringValue
            let caret = start + String(state.composition.text.prefix(state.composition.start + state.composition.length)).utf16.count
            return options(.init(text: preview, selectionStart: caret, selectionEnd: caret,
                         compositionStart: start, compositionEnd: start + state.composition.text.utf16.count))
        }, select: { start, end in
            normalizeIndices(state)
            if state.composition.isActive {
                let range = selectionRange(state) ?? state.selection.cursorIndex..<state.selection.cursorIndex
                let base = offset(range.lowerBound)
                let pending = state.composition.text
                let limit = base + pending.utf16.count
                if start >= base, end >= base, start <= limit, end <= limit {
                    func position(_ units: Int) -> Int {
                        var consumed = 0
                        for (index, glyph) in pending.enumerated() {
                            consumed += String(glyph).utf16.count
                            if units < consumed { return index }
                        }
                        return pending.count
                    }
                    let lower = position(min(start, end) - base)
                    state.composition.start = lower
                    state.composition.length = position(max(start, end) - base) - lower
                    recordCaretActivity(state)
                    return
                }
                insertReplacingSelection(pending, state: state)
            }
            state.selection.anchor = character(max(0, start))
            state.selection.cursorIndex = character(max(0, end))
            recordCaretActivity(state)
        }, deleteSurrounding: { before, after in
            guard !behavior.readOnly, !behavior.disabled else { return }
            normalizeIndices(state)
            state.clearComposition()
            let range = selectionRange(state) ?? state.selection.cursorIndex..<state.selection.cursorIndex
            let start = character(max(0, offset(range.lowerBound) - max(0, before)))
            let end = character(offset(range.upperBound) + max(0, after), roundUp: true)
            state.selection.anchor = start
            state.selection.cursorIndex = end
            _ = deleteSelection(state: state)
        })
    }
}
