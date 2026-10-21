internal import Foundation
internal import LanguageServerRuntime

extension ScriptLanguageSupport {
    public func references(scriptID: String, at position: ScriptLanguagePosition) async throws -> [ScriptDefinitionLocation] {
        let response = try await semanticRequest("textDocument/references", scriptID: scriptID) { uri in
            try Self.locationParameters(uri: uri, position: position, extra: ["context": ["includeDeclaration": true]])
        }
        return ScriptLanguageReplies.parseDefinition(response.payload).map { location in
            ScriptDefinitionLocation(documentURI: location.documentURI,
                                     scriptID: response.context.documents[location.documentURI]?.scriptID, span: location.span)
        }
    }

    public func prepareRename(scriptID: String, at position: ScriptLanguagePosition) async throws -> ScriptRenamePreparation? {
        let response = try await semanticRequest("textDocument/prepareRename", scriptID: scriptID) { uri in
            try Self.locationParameters(uri: uri, position: position)
        }
        return ScriptEditingReplies.renamePreparation(response.payload)
    }

    public func rename(scriptID: String, at position: ScriptLanguagePosition, newName: String) async throws -> ScriptWorkspaceEdit {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !newName.contains(where: { $0.isNewline || $0 == "\0" }) else { throw ScriptLanguageEditError.malformedReply }
        let response = try await semanticRequest("textDocument/rename", scriptID: scriptID) { uri in
            try Self.locationParameters(uri: uri, position: position, extra: ["newName": newName])
        }
        return try ScriptEditingReplies.workspaceEdit(response.payload, context: response.context)
    }

    public func codeActions(scriptID: String, range: ScriptLanguageSpan) async throws -> [ScriptCodeAction] {
        let diagnostics = diagnosticPayloads(scriptID: scriptID)
        let response = try await semanticRequest("textDocument/codeAction", scriptID: scriptID) { uri in
            try LSPJSON.data(["textDocument": ["uri": uri], "range": Self.rangeParameters(range),
                              "context": ["diagnostics": diagnostics.compactMap { try? JSONSerialization.jsonObject(with: $0) },
                                          "triggerKind": 1]])
        }
        return try ScriptEditingReplies.codeActions(response.payload, context: response.context)
    }

    public func resolveCodeAction(_ action: ScriptCodeAction) async throws -> ScriptCodeAction {
        guard action.disabledReason == nil else { return action }
        guard let resolution = action.resolution else { return action }
        let payload = try await resolveSemanticRequest("codeAction/resolve", params: resolution, context: action.context)
        guard let payload, let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw ScriptLanguageEditError.malformedReply
        }
        return try ScriptEditingReplies.codeAction(object, context: action.context)
    }

    public func signatureHelp(scriptID: String, at position: ScriptLanguagePosition) async throws -> ScriptSignatureHelp? {
        let response = try await semanticRequest("textDocument/signatureHelp", scriptID: scriptID) { uri in
            try Self.locationParameters(uri: uri, position: position)
        }
        return ScriptAssistanceReplies.signatures(response.payload)
    }

    public func documentSymbols(scriptID: String) async throws -> [ScriptDocumentSymbol] {
        let response = try await semanticRequest("textDocument/documentSymbol", scriptID: scriptID) { uri in
            try LSPJSON.data(["textDocument": ["uri": uri]])
        }
        return ScriptAssistanceReplies.symbols(response.payload)
    }

    public func formatting(scriptID: String, tabSize: Int = 4, insertSpaces: Bool = true) async throws -> ScriptWorkspaceEdit {
        let response = try await semanticRequest("textDocument/formatting", scriptID: scriptID) { uri in
            try LSPJSON.data(["textDocument": ["uri": uri], "options": ["tabSize": max(1, min(tabSize, 16)), "insertSpaces": insertSpaces]])
        }
        guard let document = response.context.documents.values.first(where: { $0.scriptID == scriptID }) else {
            throw ScriptLanguageEditError.staleDocument(scriptID)
        }
        guard let payload = response.payload else { return ScriptWorkspaceEdit(documents: []) }
        let value = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])
        if value is NSNull { return ScriptWorkspaceEdit(documents: []) }
        return ScriptWorkspaceEdit(documents: [ScriptDocumentEdit(scriptID: scriptID, sourceRevision: document.revision,
                                                                  edits: try ScriptEditingReplies.textEdits(value))])
    }

    private static func locationParameters(uri: String, position: ScriptLanguagePosition, extra: [String: Any] = [:]) throws -> Data {
        var parameters = extra
        parameters["textDocument"] = ["uri": uri]
        parameters["position"] = ["line": position.line, "character": position.character]
        return try LSPJSON.data(parameters)
    }

    private static func rangeParameters(_ range: ScriptLanguageSpan) -> [String: Any] {
        ["start": ["line": range.start.line, "character": range.start.character],
         "end": ["line": range.end.line, "character": range.end.character]]
    }
}
