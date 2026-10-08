import Foundation
import GuavaUICompose

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
/// Every member is a pure function over `TextBuffer`, which keeps the subtle
/// UTF-16 arithmetic testable without a running language server.
public enum ScriptSourceCoordinates {
    public static func position(in buffer: TextBuffer, atCharacterIndex index: Int) -> ScriptLanguagePosition {
        position(in: buffer, atUTF8Offset: buffer.utf8Offset(forCharacterIndex: index))
    }
    public static func position(in buffer: TextBuffer, atUTF8Offset offset: Int) -> ScriptLanguagePosition {
        let point = buffer.point(forUTF8Offset: offset)
        let start = buffer.lineRange(forLine: point.row).lowerBound
        let range = buffer.lineRange(forLine: point.row)
        let byte = min(buffer.utf8Offset(forCharacterIndex: range.upperBound), max(0, offset))
        let column = buffer.utf16Offset(forUTF8Offset: byte) - buffer.utf16Offset(forCharacterIndex: start)
        return ScriptLanguagePosition(line: point.row, character: max(0, column))
    }
    public static func characterIndex(in buffer: TextBuffer, at position: ScriptLanguagePosition) -> Int {
        buffer.characterIndex(forUTF8Offset: utf8Offset(in: buffer, at: position))
    }
    public static func utf8Offset(in buffer: TextBuffer, at position: ScriptLanguagePosition) -> Int {
        let range = buffer.lineRange(forLine: position.line)
        let start = buffer.utf16Offset(forCharacterIndex: range.lowerBound)
        let end = buffer.utf16Offset(forCharacterIndex: range.upperBound)
        return buffer.utf8Offset(forUTF16Offset: min(end, start + max(0, position.character)))
    }
    public static func identifierRange(in buffer: TextBuffer, containing index: Int) -> Range<Int>? {
        guard !buffer.isEmpty else { return nil }
        let cursor = min(buffer.characterCount, max(0, index))
        var lower = cursor, upper = cursor
        while lower > 0, let character = buffer.character(at: lower - 1), isIdentifier(character) { lower -= 1 }
        if let character = buffer.character(at: cursor), isIdentifier(character) {
            while upper < buffer.characterCount, let character = buffer.character(at: upper), isIdentifier(character) { upper += 1 }
        }
        return lower < upper ? lower..<upper : nil
    }
    private static func isIdentifier(_ character: Character) -> Bool {
        if character == "_" || character.isLetter || character.isNumber { return true }
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return scalar.value >= 0x80
    }
}
