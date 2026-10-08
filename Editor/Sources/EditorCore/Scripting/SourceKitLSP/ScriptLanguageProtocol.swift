import Foundation
import GuavaUICompose

/// Builds request payloads understood by SourceKit-LSP.
///
/// Kept separate from ``SourceKitLSPClient`` so adding a capability never means
/// touching process management — and so the payload shape can be asserted in
/// tests without a live server.
public enum ScriptLanguageQueries {
    public static let methodHover = "textDocument/hover"
    public static let methodCompletion = "textDocument/completion"
    public static let methodDefinition = "textDocument/definition"

    public static func didOpen(uri: String, text: String, version: Int) throws -> Data {
        try LSPJSON.data([
            "textDocument": [
                "uri": uri,
                "languageId": "swift",
                "version": version,
                "text": text,
            ],
        ])
    }

    public static func didChange(uri: String, previous: TextBuffer, current: TextBuffer, version: Int) throws -> Data? {
        guard let delta = current.editDelta(from: previous) else { return nil }
        let start = ScriptSourceCoordinates.position(in: previous, atUTF8Offset: delta.startUTF8Offset)
        let end = ScriptSourceCoordinates.position(in: previous, atUTF8Offset: delta.oldEndUTF8Offset)
        return try LSPJSON.data([
            "textDocument": ["uri": uri, "version": version],
            "contentChanges": [["range": ["start": ["line": start.line, "character": start.character],
                                            "end": ["line": end.line, "character": end.character]],
                                "text": delta.newText]],
        ])
    }

    public static func hover(uri: String, at position: ScriptLanguagePosition) throws -> Data {
        try LSPJSON.data(documentLocationParams(uri: uri, position: position))
    }

    public static func definition(uri: String, at position: ScriptLanguagePosition) throws -> Data {
        try LSPJSON.data(documentLocationParams(uri: uri, position: position))
    }

    public enum CompletionTrigger: Int, Sendable {
        case invoked = 1
        case triggerCharacter = 2
        case incomplete = 3
    }

    public static func completion(uri: String,
                                  at position: ScriptLanguagePosition,
                                  trigger: CompletionTrigger = .invoked,
                                  triggerCharacter: String? = nil) throws -> Data {
        var params = documentLocationParams(uri: uri, position: position)
        var context: [String: Any] = ["triggerKind": trigger.rawValue]
        if let triggerCharacter { context["triggerCharacter"] = triggerCharacter }
        params["context"] = context
        return try LSPJSON.data(params)
    }

    private static func documentLocationParams(uri: String,
                                               position: ScriptLanguagePosition) -> [String: Any] {
        [
            "textDocument": ["uri": uri],
            "position": ["line": position.line, "character": position.character],
        ]
    }
}

/// Decodes SourceKit-LSP replies into the model types the editor consumes.
///
/// The protocol permits several shapes per request (arrays vs objects, legacy
/// `MarkedString` vs `MarkupContent`, `CompletionItem[]` vs `CompletionList`).
/// Everything is treated as optional: a partially understood reply degrades to
/// "no result" instead of surfacing as an error toast over a hover request.
public enum ScriptLanguageReplies {
    // MARK: Diagnostics

    public static func parseDiagnostics(
        _ notification: SourceKitLSPNotification
    ) -> (uri: String, version: Int?, diagnostics: [ScriptLanguageDiagnostic])? {
        guard notification.method == "textDocument/publishDiagnostics",
              let params = try? JSONSerialization.jsonObject(with: notification.params) as? [String: Any],
              let uri = params["uri"] as? String,
              let diagnostics = params["diagnostics"] as? [[String: Any]] else { return nil }
        return (uri, params["version"] as? Int, diagnostics.compactMap(parseDiagnostic))
    }

    static func parseDiagnostic(_ object: [String: Any]) -> ScriptLanguageDiagnostic? {
        guard let span = parseSpan(object["range"]),
              let message = object["message"] as? String else { return nil }
        let severityValue = object["severity"] as? Int ?? ScriptDiagnosticSeverity.error.rawValue
        guard let severity = ScriptDiagnosticSeverity(rawValue: severityValue) else { return nil }
        let code: String?
        if let stringCode = object["code"] as? String {
            code = stringCode
        } else if let numericCode = object["code"] as? NSNumber {
            code = numericCode.stringValue
        } else {
            code = nil
        }
        return ScriptLanguageDiagnostic(severity: severity,
                                        startLine: span.start.line,
                                        startCharacter: span.start.character,
                                        endLine: span.end.line,
                                        endCharacter: span.end.character,
                                        message: message,
                                        code: code)
    }

    // MARK: Hover

    public static func parseHover(_ data: Data?) -> ScriptHoverResult? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let markup = parseMarkup(object["contents"]) else { return nil }
        let span = parseSpan(object["range"])
        return ScriptHoverResult(contents: markup.text,
                                 kind: markup.kind,
                                 plainText: markup.kind == .plaintext
                                    ? markup.text
                                    : ScriptMarkdownText.plainSummary(markup.text),
                                 span: span)
    }

    /// `MarkupContent`, `MarkedString`, or an array of either — SourceKit has
    /// shipped all three depending on toolchain version.
    static func parseMarkup(_ any: Any?) -> (text: String, kind: ScriptMarkupKind)? {
        switch any {
        case let string as String:
            return string.isEmpty ? nil : (string, .plaintext)
        case let array as [Any]:
            let parts = array.compactMap { parseMarkup($0) }
            guard !parts.isEmpty else { return nil }
            let joined = parts.map(\.text).joined(separator: "\n\n")
            let kind: ScriptMarkupKind = parts.contains { $0.kind == .markdown } ? .markdown : .plaintext
            return (joined, kind)
        case let object as [String: Any]:
            if let value = object["value"] as? String {
                let kind = (object["kind"] as? String) == "markdown" ? ScriptMarkupKind.markdown : .plaintext
                return (value, kind)
            }
            // Legacy `MarkedString`: { language, value }. The language tag only
            // matters for editors that switch highlighting mid-popup; Guava
            // renders one font, so the value is enough.
            if let value = object["text"] as? String { return (value, .plaintext) }
            return nil
        default:
            return nil
        }
    }

    // MARK: Completion

    public static func parseCompletion(_ data: Data?) -> ScriptCompletionResult {
        guard let data,
              let value = try? JSONSerialization.jsonObject(with: data) else { return .empty }
        let items: [[String: Any]]
        let isIncomplete: Bool
        if let list = value as? [String: Any] {
            items = list["items"] as? [[String: Any]] ?? []
            isIncomplete = list["isIncomplete"] as? Bool ?? false
        } else if let array = value as? [[String: Any]] {
            items = array
            isIncomplete = false
        } else {
            return .empty
        }
        return ScriptCompletionResult(items: items.compactMap(parseCompletionItem),
                                      isIncomplete: isIncomplete)
    }

    static func parseCompletionItem(_ object: [String: Any]) -> ScriptCompletionItem? {
        guard let label = object["label"] as? String, !label.isEmpty else { return nil }
        let kind = object["kind"] as? Int ?? 0
        let insertText: String
        let replacement: ScriptLanguageSpan?
        if let edit = object["textEdit"] as? [String: Any] {
            insertText = edit["newText"] as? String ?? label
            replacement = parseSpan(edit["range"]) ?? parseSpan(edit["replace"]) ?? parseSpan(edit["insert"])
        } else {
            insertText = object["insertText"] as? String ?? label
            replacement = nil
        }
        var item = ScriptCompletionItem(
            label: label,
            kind: ScriptCompletionItemKind(rawValue: kind),
            detail: object["detail"] as? String,
            documentation: parseMarkup(object["documentation"])?.text,
            insertText: insertText,
            replacement: replacement,
            filterText: object["filterText"] as? String,
            sortText: object["sortText"] as? String
        )
        item.usesSnippet = (object["insertTextFormat"] as? Int) == 2
        item.additionalEdits = (object["additionalTextEdits"] as? [[String: Any]] ?? []).compactMap { edit in
            guard let range = parseSpan(edit["range"]), let text = edit["newText"] as? String else { return nil }
            return ScriptCompletionTextEdit(range: range, text: text)
        }
        return item
    }

    // MARK: Definition

    public static func parseDefinition(_ data: Data?) -> [ScriptDefinitionLocation] {
        guard let data,
              let value = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let candidates: [Any]
        if let array = value as? [Any] {
            candidates = array
        } else {
            candidates = [value]
        }
        return candidates.compactMap { candidate in
            guard let object = candidate as? [String: Any] else { return nil }
            // Plain `Location` uses uri/range; `LocationLink` (3.14+) uses the
            // `target*` pair and may carry a different selection range.
            let uri = object["uri"] as? String ?? object["targetUri"] as? String
            let span = parseSpan(object["range"])
                ?? parseSpan(object["targetRange"])
                ?? parseSpan(object["targetSelectionRange"])
            guard let uri, let span else { return nil }
            return ScriptDefinitionLocation(documentURI: uri, scriptID: nil, span: span)
        }
    }

    // MARK: Shared

    static func parseSpan(_ any: Any?) -> ScriptLanguageSpan? {
        guard let object = any as? [String: Any],
              let start = object["start"] as? [String: Any],
              let end = object["end"] as? [String: Any],
              let startLine = start["line"] as? Int,
              let startCharacter = start["character"] as? Int,
              let endLine = end["line"] as? Int,
              let endCharacter = end["character"] as? Int else { return nil }
        return ScriptLanguageSpan(startLine: startLine,
                                  startCharacter: startCharacter,
                                  endLine: endLine,
                                  endCharacter: endCharacter)
    }
}
