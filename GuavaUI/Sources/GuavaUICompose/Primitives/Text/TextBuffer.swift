import Foundation

/// Immutable text with shared Rope subtrees. Copying a buffer or retaining an
/// undo snapshot is O(1). Editing visits the search path and affected graphemes.
/// Character indexes are Swift extended grapheme clusters; byte indexes are UTF-8.
public struct TextBuffer: Equatable, Sendable {
    public static let empty = TextBuffer(root: .empty, version: 0)
    let root: RopeNode
    public let version: UInt64
    private let lastEdit: BufferEdit?

    private struct BufferEdit: Sendable {
        let previousRoot: RopeNode
        let delta: TextEditDelta
    }

    private init(root: RopeNode, version: UInt64, edit: BufferEdit? = nil) {
        self.root = root; self.version = version; lastEdit = edit
    }
    public init(_ string: String) {
        self.init(root: RopeNode.build(string), version: string.isEmpty ? 0 : 1)
    }
    public var utf8Length: Int { root.metrics.utf8Length }
    public var characterCount: Int { root.metrics.characterCount }
    public var utf16Length: Int { root.metrics.utf16Length }
    /// An empty document has one line; CRLF counts as one separator.
    public var lineCount: Int { root.metrics.newlineCount + 1 }
    public var isEmpty: Bool { utf8Length == 0 }
    /// O(n). Use at file/service serialization boundaries, outside rendering.
    public var stringValue: String { String(decoding: utf8Bytes(inUTF8Range: 0..<utf8Length), as: UTF8.self) }
    /// Exact UTF-8 content equality, skipping shared subtrees. Use at edit/save
    /// boundaries and cache the result; independently loaded text may cost O(n).
    /// Ordinary == remains O(1) revision equality for rendering and observation.
    public func hasSameContents(as other: TextBuffer) -> Bool {
        if root === other.root { return true }
        guard utf8Length == other.utf8Length else { return false }
        return RopeDifference.commonBytes(root, other.root, fromEnd: false, limit: utf8Length) == utf8Length
    }
    var identity: ObjectIdentifier { ObjectIdentifier(root) }

    public func substring(characterRange: Range<Int>) -> String {
        let range = bounded(characterRange, count: characterCount)
        return String(decoding: utf8Bytes(inUTF8Range: utf8Offset(forCharacterIndex: range.lowerBound)..<utf8Offset(forCharacterIndex: range.upperBound)), as: UTF8.self)
    }
    public func character(at index: Int) -> Character? {
        guard index >= 0, index < characterCount else { return nil }
        return substring(characterRange: index..<(index + 1)).first
    }
    public func insert(_ string: String, atCharacterIndex index: Int) -> TextBuffer {
        let cursor = min(characterCount, max(0, index))
        return replace(characterRange: cursor..<cursor, with: string)
    }
    public func delete(characterRange: Range<Int>) -> TextBuffer { replace(characterRange: characterRange, with: "") }
    public func replace(characterRange: Range<Int>, with string: String) -> TextBuffer {
        let range = bounded(characterRange, count: characterCount)
        let oldText = substring(characterRange: range)
        guard oldText != string else { return self }
        let start = utf8Offset(forCharacterIndex: range.lowerBound)
        let oldEnd = utf8Offset(forCharacterIndex: range.upperBound)
        let (left, rest) = root.split(atCharacter: range.lowerBound)
        let (_, right) = rest.split(atCharacter: range.count)
        let result = RopeNode.concatenate(RopeNode.concatenate(left, .build(string)), right)
        let delta = TextEditDelta(characterRange: range, startUTF8Offset: start, oldEndUTF8Offset: oldEnd,
                                  newEndUTF8Offset: start + string.utf8.count, oldText: oldText, newText: string)
        return TextBuffer(root: result, version: version &+ 1, edit: BufferEdit(previousRoot: root, delta: delta))
    }

    /// A single edit returns its recorded delta. Multiple edits, undo and redo
    /// find the changed extent by skipping shared subtrees, without a full diff.
    public func editDelta(from previous: TextBuffer) -> TextEditDelta? {
        guard root !== previous.root else { return nil }
        if let lastEdit, lastEdit.previousRoot === previous.root { return lastEdit.delta }
        let commonStart = RopeDifference.commonBytes(previous.root, root, fromEnd: false, limit: min(previous.utf8Length, utf8Length))
        let commonEnd = RopeDifference.commonBytes(previous.root, root, fromEnd: true, limit: min(previous.utf8Length, utf8Length) - commonStart)
        if commonStart == utf8Length, utf8Length == previous.utf8Length { return nil }
        let start = min(previous.characterBoundary(beforeOrAtUTF8: commonStart), characterBoundary(beforeOrAtUTF8: commonStart))
        var trailing = commonEnd
        // Both source ranges end on grapheme boundaries. Enlarging one extent
        // also enlarges the other so replaying the delta preserves the suffix.
        while true {
            let oldEnd = previous.utf8Offset(forCharacterIndex: previous.characterIndex(forUTF8Offset: previous.utf8Length - trailing))
            let newEnd = utf8Offset(forCharacterIndex: characterIndex(forUTF8Offset: utf8Length - trailing))
            let next = min(previous.utf8Length - oldEnd, utf8Length - newEnd)
            if next == trailing { break }
            trailing = next
        }
        let oldEnd = previous.utf8Length - trailing, newEnd = utf8Length - trailing
        let range = previous.characterIndex(forUTF8Offset: start)..<previous.characterIndex(forUTF8Offset: oldEnd)
        return TextEditDelta(characterRange: range, startUTF8Offset: start, oldEndUTF8Offset: oldEnd, newEndUTF8Offset: newEnd,
                             oldText: String(decoding: previous.utf8Bytes(inUTF8Range: start..<oldEnd), as: UTF8.self),
                             newText: String(decoding: utf8Bytes(inUTF8Range: start..<newEnd), as: UTF8.self))
    }
    private func characterBoundary(beforeOrAtUTF8 offset: Int) -> Int {
        let index = characterIndex(forUTF8Offset: offset)
        let boundary = utf8Offset(forCharacterIndex: index)
        return boundary > offset ? utf8Offset(forCharacterIndex: index - 1) : boundary
    }
    public func utf8Offset(forCharacterIndex index: Int) -> Int { root.utf8Offset(characterIndex: min(characterCount, max(0, index))) }
    /// Offsets inside a grapheme snap forward to its end.
    public func characterIndex(forUTF8Offset offset: Int) -> Int { root.characterIndex(utf8Offset: min(utf8Length, max(0, offset))) }
    public func utf16Offset(forCharacterIndex index: Int) -> Int { root.utf16Offset(characterIndex: min(characterCount, max(0, index))) }
    /// Range excludes the separator; out-of-range lines clamp to the document.
    public func lineRange(forLine line: Int) -> Range<Int> {
        let row = min(lineCount - 1, max(0, line))
        let start = row == 0 ? 0 : root.newlineCharacterIndex(ordinal: row - 1) + 1
        let end = row == lineCount - 1 ? characterCount : root.newlineCharacterIndex(ordinal: row)
        return start..<end
    }
    public func characterIndex(forLine line: Int, character: Int) -> Int {
        let range = lineRange(forLine: line)
        return range.lowerBound + min(range.count, max(0, character))
    }
    public func lineIndex(forCharacterIndex index: Int) -> Int { root.newlines(beforeCharacter: min(characterCount, max(0, index))) }
    public func lineAndColumn(forCharacterIndex index: Int) -> (line: Int, column: Int) {
        let cursor = min(characterCount, max(0, index)), line = lineIndex(forCharacterIndex: index)
        return (line, cursor - lineRange(forLine: line).lowerBound)
    }
    public func point(forUTF8Offset offset: Int) -> TextBufferPoint {
        let byte = min(utf8Length, max(0, offset))
        let forward = characterIndex(forUTF8Offset: byte)
        let character = utf8Offset(forCharacterIndex: forward) > byte ? forward - 1 : forward
        let row = lineIndex(forCharacterIndex: character)
        return TextBufferPoint(row: row, columnUTF8: byte - utf8Offset(forCharacterIndex: lineRange(forLine: row).lowerBound))
    }

    /// Tree-sitter rows count LF bytes; a CRLF edit can end between its two
    /// bytes, independently of the grapheme/visual-line coordinate space.
    public func parserPoint(forUTF8Offset offset: Int) -> TextBufferPoint {
        let byte = min(utf8Length, max(0, offset)), row = root.lineFeeds(beforeByte: min(utf8Length, max(0, offset)))
        let start = row == 0 ? 0 : root.lineFeedByteIndex(ordinal: row - 1) + 1
        return TextBufferPoint(row: row, columnUTF8: byte - start)
    }
    /// UTF-16 code-unit conversion for LSP. Scalar interiors snap forward;
    /// combining-scalar boundaries remain representable within a Character.
    public func utf8Offset(forUTF16Offset offset: Int) -> Int {
        root.utf8Offset(utf16Offset: min(utf16Length, max(0, offset)))
    }
    public func utf16Offset(forUTF8Offset offset: Int) -> Int {
        root.utf16Offset(utf8Offset: min(utf8Length, max(0, offset)))
    }

    /// Overlapping immutable leaves, including partially covered edge leaves.
    /// For an exact byte slice, use `utf8Bytes(inUTF8Range:)` or `chunk(atUTF8Offset:)`.
    public func visibleChunks(inUTF8Range range: Range<Int>) -> [RopeLeaf] {
        root.leaves(in: bounded(range, count: utf8Length))
    }
    public func utf8Bytes(inUTF8Range range: Range<Int>) -> [UInt8] {
        let range = bounded(range, count: utf8Length)
        var bytes: [UInt8] = []; bytes.reserveCapacity(range.count)
        root.appendBytes(in: range, to: &bytes)
        return bytes
    }
    public func chunk(atUTF8Offset offset: Int) -> RopeChunk? {
        guard offset >= 0, offset < utf8Length else { return nil }
        return root.chunk(at: offset, base: 0)
    }
    public func visibleText(firstLine: Int, lastLine: Int) -> String {
        let first = min(lineCount - 1, max(0, firstLine)), last = min(lineCount - 1, max(first, lastLine))
        return substring(characterRange: lineRange(forLine: first).lowerBound..<lineRange(forLine: last).upperBound)
    }
    private func bounded(_ range: Range<Int>, count: Int) -> Range<Int> {
        let lower = min(count, max(0, range.lowerBound))
        return lower..<min(count, max(lower, range.upperBound))
    }
    /// Revision equality is O(1). Independently constructed buffers are distinct
    /// revisions even when their serialized strings have identical contents.
    public static func == (lhs: TextBuffer, rhs: TextBuffer) -> Bool { lhs.root === rhs.root }
}

extension TextBuffer: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self.init(value) }
}

public struct TextBufferPoint: Equatable, Sendable {
    public let row: Int
    public let columnUTF8: Int
}
/// UTF-8 spans feed Tree-sitter. LSP ranges must be converted to UTF-16 positions.
public struct TextEditDelta: Equatable, Sendable {
    public let characterRange: Range<Int>
    public let startUTF8Offset: Int
    public let oldEndUTF8Offset: Int
    public let newEndUTF8Offset: Int
    public let oldText: String
    public let newText: String
    public var isInsertion: Bool { characterRange.isEmpty && !newText.isEmpty }
    public var isDeletion: Bool { !characterRange.isEmpty && newText.isEmpty }
}
