import Foundation
import EditorCore
import CoveUI

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
            item.detail = source.detail; item.documentation = source.documentation; item.filterText = source.filterText
            item.replacement = source.replacement.map(range)
            item.additionalEdits = source.additionalEdits.map { TextCompletionEdit(range: range($0.range), text: $0.text) }
            return item
        }
    }
}

/// The server's items behind the list on screen, so a highlighted one can
/// fetch the documentation the list left out.
@MainActor
final class ScriptCompletionItems {
    private var items: [String: ScriptCompletionItem] = [:]

    func convert(_ result: ScriptCompletionResult, for request: TextCompletionRequest) -> [TextCompletionItem] {
        items = Dictionary(result.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ScriptCompletionConversion.items(result, for: request)
    }

    nonisolated func resolver(_ manager: DynamicScriptManager) -> TextCompletionResolver {
        { [weak self] item, reply in
            Task { @MainActor in
                guard let source = self?.items[item.id],
                      let resolved = try? await manager.resolveCompletion(source) else { reply(item); return }
                var next = item
                next.documentation = resolved.documentation
                next.detail = resolved.detail ?? item.detail
                reply(next)
            }
        }
    }
}
