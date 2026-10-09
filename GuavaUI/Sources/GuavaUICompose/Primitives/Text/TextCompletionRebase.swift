import Foundation

/// A provider reply belongs to one document revision. Retain it only while
/// typing or deleting at the end of the same identifier; every edit range is
/// moved through UTF-8 so grapheme joins cannot leave stale Character indexes.
enum TextCompletionRebase {
    static func candidates(_ items: [TextCompletionItem], from old: TextCompletionRequest,
                           to next: TextCompletionRequest) -> [TextCompletionItem] {
        guard old.prefixRange.lowerBound == next.prefixRange.lowerBound,
              let delta = next.buffer.editDelta(from: old.buffer),
              delta.characterRange.lowerBound >= old.prefixRange.lowerBound,
              delta.characterRange.upperBound <= old.prefixRange.upperBound,
              delta.oldEndUTF8Offset == old.utf8Offset,
              delta.newEndUTF8Offset == next.utf8Offset else { return [] }
        return items.compactMap { item in
            var result = item
            if let range = item.replacement {
                guard range.lowerBound <= old.prefixRange.lowerBound, range.upperBound >= old.caretIndex,
                      let moved = move(range, old: old.buffer, next: next.buffer, delta: delta, includesChange: true) else { return nil }
                result.replacement = moved
            }
            var edits: [TextCompletionEdit] = []
            for edit in item.additionalEdits {
                guard let range = move(edit.range, old: old.buffer, next: next.buffer, delta: delta, includesChange: false) else { return nil }
                edits.append(TextCompletionEdit(range: range, text: edit.text))
            }
            result.additionalEdits = edits
            return result
        }
    }
    private static func move(_ range: Range<Int>, old: TextBuffer, next: TextBuffer,
                             delta: TextEditDelta, includesChange: Bool) -> Range<Int>? {
        guard range.lowerBound >= 0, range.upperBound <= old.characterCount else { return nil }
        var start = old.utf8Offset(forCharacterIndex: range.lowerBound)
        var end = old.utf8Offset(forCharacterIndex: range.upperBound)
        let shift = delta.newEndUTF8Offset - delta.oldEndUTF8Offset
        if includesChange { end += shift }
        else if end <= delta.startUTF8Offset { /* Edits before the prefix keep their anchor. */ }
        else if start >= delta.oldEndUTF8Offset { start += shift; end += shift }
        else { return nil }
        guard start >= 0, end >= start, end <= next.utf8Length else { return nil }
        let lower = next.characterIndex(forUTF8Offset: start), upper = next.characterIndex(forUTF8Offset: end)
        guard next.utf8Offset(forCharacterIndex: lower) == start,
              next.utf8Offset(forCharacterIndex: upper) == end else { return nil }
        return lower..<upper
    }
}
