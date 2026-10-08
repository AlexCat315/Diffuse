import GuavaUIRuntime

extension TextField {
    func indentedNewline(state: FieldState) -> String {
        guard let width = codeEditing.indentationWidth, layout.axis == .vertical else { return "\n" }
        let buffer = text.wrappedValue
        let cursor = selectionRange(state)?.lowerBound ?? state.selection.cursorIndex
        let range = buffer.lineRange(forLine: buffer.lineIndex(forCharacterIndex: cursor))
        let line = buffer.substring(characterRange: range.lowerBound..<min(range.upperBound, cursor))
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let last = line.last { !$0.isWhitespace }
        let extra = last == "{" || last == "[" ? String(repeating: " ", count: width) : ""
        return "\n" + indent + extra
    }

    func indentLines(width: Int, removing: Bool, state: FieldState) {
        beginEdit(state, kind: .atomic)
        defer { endEdit(state) }
        normalizeIndices(state)
        let previous = text.wrappedValue
        var next = previous, cursor = state.selection.cursorIndex, anchor = state.selection.anchor
        let selection = selectionRange(state)
        let lower = selection?.lowerBound ?? cursor
        let upper = selection.map { max($0.lowerBound, $0.upperBound - 1) } ?? lower
        let first = previous.lineIndex(forCharacterIndex: lower), last = previous.lineIndex(forCharacterIndex: upper)
        for line in (first...last).reversed() {
            let start = previous.lineRange(forLine: line).lowerBound
            let removed: Int, insertion: String
            if removing {
                var count = 0
                while count < width, next.character(at: start + count) == " " { count += 1 }
                if count == 0, next.character(at: start) == "\t" { count = 1 }
                removed = count; insertion = ""
            } else {
                removed = 0
                let spaces = selection == nil ? width - ((cursor - start) % width) : width
                insertion = String(repeating: " ", count: spaces)
            }
            let offset = !removing && selection == nil ? cursor : start
            let edited = next.replace(characterRange: offset..<(offset + removed), with: insertion)
            let shift = edited.characterCount - next.characterCount
            func moved(_ index: Int) -> Int { index < offset ? index : max(offset, index + shift) }
            cursor = moved(cursor); anchor = anchor.map(moved); next = edited
        }
        if let maxLength = behavior.maxLength, next.characterCount > maxLength { return }
        guard next != previous else { return }
        text.wrappedValue = next
        state.selection.cursorIndex = cursor; state.selection.anchor = anchor
        state.clearComposition(); state.selection.preferredCaretX = nil
        recordCaretActivity(state); events.onChange?(next)
    }
}
