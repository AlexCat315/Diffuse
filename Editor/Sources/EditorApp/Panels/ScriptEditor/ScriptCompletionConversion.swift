import Foundation
import EditorCore
import GuavaUICompose

enum ScriptCompletionConversion {
    static func items(_ result: ScriptCompletionResult, for request: TextCompletionRequest) -> [TextCompletionItem] {
        func range(_ span: ScriptLanguageSpan) -> Range<Int> {
            let start = ScriptSourceCoordinates.characterIndex(in: request.buffer, at: span.start)
            let end = ScriptSourceCoordinates.characterIndex(in: request.buffer, at: span.end)
            return start..<max(start, end)
        }
        return result.items.sorted { ($0.sortText ?? $0.label) < ($1.sortText ?? $1.label) }.map { source in
            var item = TextCompletionItem(id: source.id, label: source.label,
                insertText: source.usesSnippet ? plainSnippet(source.insertText) : source.insertText)
            item.detail = source.detail; item.filterText = source.filterText
            item.replacement = source.replacement.map(range)
            item.additionalEdits = source.additionalEdits.map { TextCompletionEdit(range: range($0.range), text: $0.text) }
            return item
        }
    }
    /// Plain-text fallback for servers ignoring snippetSupport=false. Defaults
    /// are retained; tab-stop navigation is not advertised to the server.
    static func plainSnippet(_ source: String) -> String {
        var text = "", index = source.startIndex
        while index < source.endIndex {
            let character = source[index]; index = source.index(after: index)
            if character == "\\", index < source.endIndex {
                text.append(source[index]); index = source.index(after: index); continue
            }
            guard character == "$", index < source.endIndex else { text.append(character); continue }
            if source[index].isNumber {
                while index < source.endIndex, source[index].isNumber { index = source.index(after: index) }
            } else if source[index] == "{", let end = source[index...].firstIndex(of: "}") {
                let body = source[source.index(after: index)..<end]
                if let colon = body.firstIndex(of: ":") { text += plainSnippet(String(body[body.index(after: colon)...])) }
                else if let bar = body.firstIndex(of: "|") { text += body[body.index(after: bar)...].split(separator: ",").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "|")) ?? "" }
                index = source.index(after: end)
            } else { text.append(character) }
        }
        return text
    }
}
