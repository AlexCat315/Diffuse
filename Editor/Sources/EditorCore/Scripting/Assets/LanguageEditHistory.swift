import Foundation
import GuavaUICompose

struct ScriptLanguageEditHistory {
    struct Change {
        let scriptID: String
        let before: TextBuffer
        let after: TextBuffer
    }

    var undo: [[Change]] = []
    var redo: [[Change]] = []

    mutating func record(_ changes: [Change]) {
        guard !changes.isEmpty else { return }
        undo.append(changes)
        if undo.count > 50 { undo.removeFirst() }
        redo.removeAll()
    }
}

enum ScriptLanguageEditValidation {
    static func range(_ span: ScriptLanguageSpan, in source: TextBuffer) throws -> Range<Int> {
        let lower = try index(span.start, in: source)
        let upper = try index(span.end, in: source)
        guard lower <= upper else { throw ScriptLanguageEditError.invalidRange }
        return lower..<upper
    }

    private static func index(_ position: ScriptLanguagePosition, in source: TextBuffer) throws -> Int {
        guard position.line >= 0, position.line < source.lineCount, position.character >= 0 else {
            throw ScriptLanguageEditError.invalidRange
        }
        let index = ScriptSourceCoordinates.characterIndex(in: source, at: position)
        guard ScriptSourceCoordinates.position(in: source, atCharacterIndex: index) == position else {
            throw ScriptLanguageEditError.invalidRange
        }
        return index
    }
}
