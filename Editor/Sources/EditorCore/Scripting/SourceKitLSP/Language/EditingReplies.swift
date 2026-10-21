internal import Foundation

enum ScriptEditingReplies {
    static func workspaceEdit(_ data: Data?, context: ScriptSemanticContext) throws -> ScriptWorkspaceEdit {
        guard let data else { return ScriptWorkspaceEdit(documents: []) }
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if value is NSNull { return ScriptWorkspaceEdit(documents: []) }
        guard let object = value as? [String: Any] else { throw ScriptLanguageEditError.malformedReply }
        var documents: [String: ScriptDocumentEdit] = [:]
        func append(uri: String, version: Int?, edits: Any?) throws {
            guard let url = URL(string: uri), url.isFileURL,
                  let document = context.documents[url.standardizedFileURL.absoluteString] else {
                throw ScriptLanguageEditError.externalDocument(uri)
            }
            if let version, version != document.version { throw ScriptLanguageEditError.staleDocument(document.scriptID) }
            let parsed = try textEdits(edits)
            let existing = documents[document.scriptID]?.edits ?? []
            documents[document.scriptID] = ScriptDocumentEdit(scriptID: document.scriptID, sourceRevision: document.revision,
                                                            edits: existing + parsed)
        }
        if let changes = object["changes"] {
            guard let changes = changes as? [String: Any] else { throw ScriptLanguageEditError.malformedReply }
            for (uri, edits) in changes { try append(uri: uri, version: nil, edits: edits) }
        }
        if let changes = object["documentChanges"] {
            guard let changes = changes as? [[String: Any]] else { throw ScriptLanguageEditError.malformedReply }
            for change in changes {
                if change["kind"] != nil { throw ScriptLanguageEditError.unsupportedResourceOperation }
                guard let document = change["textDocument"] as? [String: Any], let uri = document["uri"] as? String else {
                    throw ScriptLanguageEditError.malformedReply
                }
                try append(uri: uri, version: document["version"] as? Int, edits: change["edits"])
            }
        }
        return ScriptWorkspaceEdit(documents: documents.values.sorted { $0.scriptID < $1.scriptID })
    }

    static func textEdits(_ value: Any?) throws -> [ScriptCompletionTextEdit] {
        guard let edits = value as? [[String: Any]] else { throw ScriptLanguageEditError.malformedReply }
        return try edits.map { edit in
            guard let range = ScriptLanguageReplies.parseSpan(edit["range"]), let text = edit["newText"] as? String else {
                throw ScriptLanguageEditError.malformedReply
            }
            return ScriptCompletionTextEdit(range: range, text: text)
        }
    }

    static func codeActions(_ data: Data?, context: ScriptSemanticContext) throws -> [ScriptCodeAction] {
        guard let data else { return [] }
        let value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if value is NSNull { return [] }
        guard let objects = value as? [[String: Any]] else { throw ScriptLanguageEditError.malformedReply }
        return try objects.map { try codeAction($0, context: context) }
    }

    static func codeAction(_ object: [String: Any], context: ScriptSemanticContext) throws -> ScriptCodeAction {
        guard let title = object["title"] as? String else { throw ScriptLanguageEditError.malformedReply }
        var disabled = (object["disabled"] as? [String: Any])?["reason"] as? String
        if object["command"] != nil { disabled = ScriptLanguageEditError.unsupportedCommand.localizedDescription }
        let edit = try object["edit"].map { try workspaceEdit(JSONSerialization.data(withJSONObject: $0), context: context) }
        let resolution = object["data"] != nil ? try JSONSerialization.data(withJSONObject: object) : nil
        if edit == nil, resolution == nil, disabled == nil { disabled = "This action does not provide an applicable edit." }
        return ScriptCodeAction(title: title, kind: object["kind"] as? String, isPreferred: object["isPreferred"] as? Bool ?? false,
                                disabledReason: disabled, edit: edit, resolution: resolution, context: context)
    }

    static func renamePreparation(_ data: Data?) -> ScriptRenamePreparation? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let range = ScriptLanguageReplies.parseSpan(object["range"] ?? object) else { return nil }
        return ScriptRenamePreparation(range: range, placeholder: object["placeholder"] as? String)
    }
}
