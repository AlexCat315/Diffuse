import Foundation
import EditorCore
import GuavaUI

enum ScriptCompletionConversion {
    static func items(_ result: ScriptCompletionResult, for request: TextCompletionRequest) -> [TextCompletionItem] {
        func range(_ span: ScriptLanguageSpan) -> Range<Int> {
            let start = ScriptSourceCoordinates.characterIndex(in: request.buffer, at: span.start)
            let end = ScriptSourceCoordinates.characterIndex(in: request.buffer, at: span.end)
            return start..<max(start, end)
        }
        return result.items.sorted { ($0.sortText ?? $0.label) < ($1.sortText ?? $1.label) }.map { source in
            var item = TextCompletionItem(id: source.id, label: source.label, insertText: source.insertText)
            item.insertTextFormat = source.usesSnippet ? .snippet : .plainText
            item.detail = source.detail; item.filterText = source.filterText
            item.replacement = source.replacement.map(range)
            item.additionalEdits = source.additionalEdits.map { TextCompletionEdit(range: range($0.range), text: $0.text) }
            return item
        }
    }
}
