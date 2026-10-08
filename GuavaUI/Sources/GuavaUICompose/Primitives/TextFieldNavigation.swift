import GuavaUIRuntime

extension TextField {
    /// Line commands follow the displayed row. Without a shaping environment,
    /// the Rope still provides a deterministic logical-line boundary.
    func lineBoundary(ending: Bool, state: FieldState, node: Node) -> Int {
        let buffer = text.wrappedValue
        guard layout.axis == .vertical else { return ending ? buffer.characterCount : 0 }
        if layout.wrapsLines, let env = TextEnvironmentHolder.current {
            let document = layoutEngine(for: node).interactiveDocument(in: buffer, node: node, env: env)
            let caret = document.caret(atCharacter: state.selection.cursorIndex,
                lineEndAffinity: state.selection.lineEndAffinity, environment: env)
            return document.character(atRow: caret.row, x: ending ? .infinity : 0, environment: env)
        }
        let range = buffer.lineRange(forLine: buffer.lineIndex(forCharacterIndex: state.selection.cursorIndex))
        return ending ? range.upperBound : range.lowerBound
    }

    func moveToLineBoundary(ending: Bool, extendSelection: Bool, state: FieldState, node: Node) {
        moveCursor(to: lineBoundary(ending: ending, state: state, node: node),
            extendSelection: extendSelection, state: state)
        // A soft-wrap boundary has two visual positions at one Character index.
        // End belongs to the preceding row, so retain that position for paint,
        // IME, hover and the next vertical move.
        state.selection.lineEndAffinity = ending
    }

    func moveCursorVertically(lineDelta: Int, extendSelection: Bool, state: FieldState, node: Node) {
        guard lineDelta != 0 else { return }
        guard let env = TextEnvironmentHolder.current else {
            let buffer = text.wrappedValue
            let position = buffer.lineAndColumn(forCharacterIndex: state.selection.cursorIndex)
            let row = clamp(position.line + lineDelta, 0, buffer.lineCount - 1)
            moveCursor(to: buffer.characterIndex(forLine: row, character: position.column),
                extendSelection: extendSelection, state: state)
            return
        }
        let document = layoutEngine(for: node).interactiveDocument(in: text.wrappedValue, node: node, env: env)
        let caret = document.caret(atCharacter: state.selection.cursorIndex,
            lineEndAffinity: state.selection.lineEndAffinity, environment: env)
        let targetRow = clamp(caret.row + lineDelta, 0, document.index.rowCount - 1)
        let desiredX = state.selection.preferredCaretX ?? caret.x
        let target = document.character(atRow: targetRow, x: desiredX, environment: env)
        moveCursor(to: target, extendSelection: extendSelection, state: state, preferredCaretX: desiredX)
        state.selection.lineEndAffinity = document.caret(atCharacter: target,
            lineEndAffinity: true, environment: env).row == targetRow
    }

    func moveCursorByPage(direction: Int, extendSelection: Bool, state: FieldState, node: Node) -> Bool {
        guard layout.axis == .vertical, let env = TextEnvironmentHolder.current else { return false }
        let height = resolvedLineHeight(node: node, env: env)
        let visible = max(height, Float(node.frame.height) - Self.verticalInset(for: height) * 2)
        let rows = max(1, Int(floor(visible / max(1, height))) - 1)
        moveCursorVertically(lineDelta: direction * rows, extendSelection: extendSelection, state: state, node: node)
        return true
    }
}
