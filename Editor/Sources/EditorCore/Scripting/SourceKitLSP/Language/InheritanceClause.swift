import CoveUICompose

/// Reads a type declaration's inheritance clause straight from source, for
/// when the server's index has no type hierarchy (types from binary modules).
enum ScriptInheritanceClause {
    /// Positions of each inherited type's name in `struct Name<T>: A, B.C & D {`,
    /// given the position of `Name`. Qualified names point at their last part.
    static func typePositions(in text: TextBuffer, declarationAt position: ScriptLanguagePosition) -> [ScriptLanguagePosition] {
        let start = ScriptSourceCoordinates.characterIndex(in: text, at: position)
        let window = Array(text.substring(characterRange: start..<min(text.characterCount, start + 600)))
        var index = 0
        func skipSpace() { while index < window.count, window[index].isWhitespace { index += 1 } }
        func isName(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }
        func skipGenerics() {
            guard index < window.count, window[index] == "<" else { return }
            var depth = 0
            while index < window.count {
                if window[index] == "<" { depth += 1 } else if window[index] == ">" { depth -= 1 }
                index += 1
                if depth == 0 { return }
            }
        }
        while index < window.count, isName(window[index]) { index += 1 }
        skipSpace(); skipGenerics(); skipSpace()
        guard index < window.count, window[index] == ":" else { return [] }
        index += 1
        var positions: [ScriptLanguagePosition] = []
        while true {
            skipSpace()
            guard index < window.count, isName(window[index]) else { break }
            var last = index
            while index < window.count, isName(window[index]) || window[index] == "." {
                if window[index] == "." { last = index + 1 }
                index += 1
            }
            positions.append(ScriptSourceCoordinates.position(in: text, atCharacterIndex: start + last))
            skipGenerics(); skipSpace()
            guard index < window.count, window[index] == "," || window[index] == "&" else { break }
            index += 1
        }
        return positions
    }
}
