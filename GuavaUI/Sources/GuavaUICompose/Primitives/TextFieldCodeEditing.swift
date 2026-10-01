import GuavaUIRuntime

extension TextField {
    func indentedNewline(state: FieldState) -> String {
        guard let width = indentationWidth, axis == .vertical else { return "\n" }
        let cursor = selectionRange(state)?.lowerBound ?? state.cursorIndex
        let prefix = text.wrappedValue.prefix(cursor)
        let line = prefix.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let last = line.last { !$0.isWhitespace }
        let extra = last == "{" || last == "[" ? String(repeating: " ", count: width) : ""
        return "\n" + indent + extra
    }

    func indentLines(width: Int, removing: Bool, state: FieldState) {
        beginEdit(state, kind: .atomic)
        defer { endEdit(state) }
        normalizeIndices(state)
        var characters = Array(text.wrappedValue)
        var cursor = state.cursorIndex
        var anchor = state.selectionAnchor
        let selection = selectionRange(state)
        let lower = selection?.lowerBound ?? state.cursorIndex
        let upper = selection.map { max($0.lowerBound, $0.upperBound - 1) } ?? lower
        var start = lower
        while start > 0, characters[start - 1] != "\n" { start -= 1 }
        var starts = [start]
        if start < upper {
            for index in start..<upper where characters[index] == "\n" { starts.append(index + 1) }
        }

        for offset in starts.reversed() {
            let removed: Int
            let inserted: [Character]
            if removing {
                var count = 0
                while offset + count < characters.count, count < width,
                      characters[offset + count] == " " { count += 1 }
                if count == 0, offset < characters.count, characters[offset] == "\t" { count = 1 }
                removed = count
                inserted = []
            } else {
                removed = 0
                let spaces = selection == nil ? width - ((cursor - start) % width) : width
                inserted = Array(repeating: " ", count: spaces)
            }
            // A single caret inserts at its tab stop; selections indent entire lines.
            let editOffset = !removing && selection == nil ? cursor : offset
            characters.replaceSubrange(editOffset..<(editOffset + removed), with: inserted)
            func moved(_ index: Int) -> Int {
                index < editOffset ? index : max(editOffset, index - removed) + inserted.count
            }
            cursor = moved(cursor)
            anchor = anchor.map(moved)
        }
        if let maxLength, characters.count > maxLength { return }
        let next = String(characters)
        guard next != text.wrappedValue else { return }
        text.wrappedValue = next
        state.cursorIndex = cursor
        state.selectionAnchor = anchor
        state.clearComposition()
        state.preferredCaretX = nil
        recordCaretActivity(state)
        onChange?(next)
    }
}
