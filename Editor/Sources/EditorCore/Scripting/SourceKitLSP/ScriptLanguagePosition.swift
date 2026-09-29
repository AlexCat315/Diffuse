import Foundation

/// A zero-based `line` / UTF-16 `character` offset — the coordinate space the
/// Language Server Protocol mandates.
///
/// The editor's text field tracks offsets in `Character` (grapheme cluster)
/// units, LSP talks UTF-16 code units, and the script highlighter works in UTF-8
/// bytes. Mixing them silently shifts every column for non-BMP characters, so
/// all three conversions funnel through ``ScriptSourceCoordinates``.
public struct ScriptLanguagePosition: Sendable, Equatable, Hashable {
    public let line: Int
    /// Offset measured in UTF-16 code units from the start of the line.
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    public static let zero = ScriptLanguagePosition(line: 0, character: 0)
}

/// A half-open `[start, end)` range in LSP coordinates.
public struct ScriptLanguageSpan: Sendable, Equatable, Hashable {
    public let start: ScriptLanguagePosition
    public let end: ScriptLanguagePosition

    public init(start: ScriptLanguagePosition, end: ScriptLanguagePosition) {
        self.start = start
        self.end = end
    }

    public init(startLine: Int,
                startCharacter: Int,
                endLine: Int,
                endCharacter: Int) {
        self.start = ScriptLanguagePosition(line: startLine, character: startCharacter)
        self.end = ScriptLanguagePosition(line: endLine, character: endCharacter)
    }
}

/// Conversions between editor indices and LSP positions.
///
/// Every member is a pure function over `String`, which keeps the subtle
/// UTF-16 arithmetic testable without a running language server.
public enum ScriptSourceCoordinates {

    // MARK: - Line splitting

    /// Half-open ranges covering each line's content, excluding the trailing
    /// newline. A text ending in `\n` yields an additional empty final line,
    /// matching how editors show a caret below the last visible row.
    public static func lineRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while true {
            if let newline = text[start...].firstIndex(of: "\n") {
                ranges.append(start..<newline)
                let next = text.index(after: newline)
                if next == text.endIndex {
                    ranges.append(next..<next)
                    break
                }
                start = next
            } else {
                ranges.append(start..<text.endIndex)
                break
            }
        }
        return ranges
    }

    // MARK: - Editor index → LSP position

    /// Converts a `Character` offset within `text` into an LSP position.
    ///
    /// Out-of-range offsets clamp to the nearest valid position rather than
    /// trapping: the caret index is captured from a render pass and the bound
    /// text may have been rewritten since.
    public static func position(in text: String, atCharacterIndex index: Int) -> ScriptLanguagePosition {
        let count = text.count
        guard count > 0 else { return .zero }
        let lines = lineRanges(in: text)
        let bounded = min(max(index, 0), count)
        let target = text.index(text.startIndex, offsetBy: bounded)

        // A caret parked directly after the line's content still belongs to
        // that line; the following line starts *past* the newline, so its lower
        // bound never matches this index and `first` resolves correctly.
        if let lineIndex = lines.indices.first(where: {
            lines[$0].lowerBound <= target && target <= lines[$0].upperBound
        }) {
            let utf16 = text.utf16.distance(from: lines[lineIndex].lowerBound, to: target)
            return ScriptLanguagePosition(line: lineIndex, character: max(0, utf16))
        }

        guard let last = lines.last else { return .zero }
        return ScriptLanguagePosition(line: max(0, lines.count - 1),
                                      character: max(0, text.utf16.distance(from: last.lowerBound,
                                                                            to: text.endIndex)))
    }

    // MARK: - LSP position → editor index

    /// Converts an LSP position back into a `Character` offset, clamped to the
    /// enclosing line so an imprecise server reply can never produce an
    /// out-of-bounds `String.Index`.
    public static func characterIndex(in text: String, at position: ScriptLanguagePosition) -> Int {
        let lines = lineRanges(in: text)
        guard !lines.isEmpty else { return 0 }
        let lineIndex = min(max(position.line, 0), lines.count - 1)
        let range = lines[lineIndex]
        guard position.character > 0 else {
            return text.distance(from: text.startIndex, to: range.lowerBound)
        }
        guard let target = text.utf16.index(range.lowerBound,
                                            offsetBy: position.character,
                                            limitedBy: range.upperBound) else {
            return text.distance(from: text.startIndex, to: range.upperBound)
        }
        return text.distance(from: text.startIndex, to: target)
    }

    /// UTF-8 byte offset for a position — the unit the script highlighter and
    /// the text field's colouring callback use.
    public static func utf8Offset(in text: String, at position: ScriptLanguagePosition) -> Int {
        let index = characterIndex(in: text, at: position)
        guard let converted = text.index(text.startIndex,
                                         offsetBy: index,
                                         limitedBy: text.endIndex) else { return 0 }
        return text.utf8.distance(from: text.startIndex, to: converted)
    }

    // MARK: - Word queries

    /// The Swift identifier enclosing `index`, used to decide what to ask about
    /// when hovering or completing. Returns `nil` when the caret sits on
    /// whitespace or punctuation.
    ///
    /// Member accesses intentionally yield the trailing component:
    /// `context.deltaTime` focused anywhere inside `deltaTime` reports
    /// `deltaTime`, so the language server resolves the member rather than the
    /// value it is read from.
    public static func identifierRange(in text: String, containing index: Int) -> Range<Int>? {
        let count = text.count
        guard count > 0 else { return nil }
        let clamped = min(max(index, 0), count)
        guard clamped < count else { return trailingIdentifier(in: text, before: count) }
        let cursor = text.index(text.startIndex, offsetBy: clamped)
        guard isIdentifier(text[cursor]) else {
            return trailingIdentifier(in: text, before: clamped)
        }

        var lower = clamped
        var scanner = cursor
        while scanner > text.startIndex {
            let previous = text.index(before: scanner)
            guard isIdentifier(text[previous]) else { break }
            scanner = previous
            lower -= 1
        }
        var upper = clamped
        var forward = cursor
        while forward < text.endIndex {
            guard isIdentifier(text[forward]) else { break }
            forward = text.index(after: forward)
            upper += 1
        }
        guard lower < upper else { return nil }
        return lower..<upper
    }

    /// Identifier immediately before `index` — the prefix a completion request
    /// should filter on while the caret trails a partially typed word.
    private static func trailingIdentifier(in text: String, before index: Int) -> Range<Int>? {
        guard index > 0 else { return nil }
        var upper = index
        var scanner = text.index(text.startIndex, offsetBy: index)
        while scanner > text.startIndex {
            let previous = text.index(before: scanner)
            guard isIdentifier(text[previous]) else { break }
            scanner = previous
            upper -= 1
        }
        guard upper < index else { return nil }
        return upper..<index
    }

    /// Approximates Swift's identifier character set. Anything outside ASCII is
    /// treated as a possible identifier body — Swift source routinely contains
    /// accented and CJK names, and a false positive only widens the token the
    /// language server is asked about.
    private static func isIdentifier(_ character: Character) -> Bool {
        if character == "_" { return true }
        if character.isLetter || character.isNumber { return true }
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        return scalar.value >= 0x80
    }
}
