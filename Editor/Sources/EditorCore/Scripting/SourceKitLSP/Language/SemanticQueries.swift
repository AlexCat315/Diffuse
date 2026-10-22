import Foundation
import LanguageServerRuntime

extension ScriptLanguageSupport {
    public func references(scriptID: String, at position: ScriptLanguagePosition) async throws -> [ScriptDefinitionLocation] {
        let response = try await semanticRequest("textDocument/references", scriptID: scriptID) { uri in
            try Self.locationParameters(uri: uri, position: position, extra: ["context": ["includeDeclaration": true]])
        }
        return ScriptLanguageReplies.parseDefinition(response.payload).map { location in
            ScriptDefinitionLocation(documentURI: location.documentURI,
                                     scriptID: response.context.document(for: location.documentURI)?.scriptID, span: location.span)
        }
    }

    /// Conformers of a protocol requirement and overrides of a member.
    public func implementations(scriptID: String, at position: ScriptLanguagePosition) async throws -> [ScriptDefinitionLocation] {
        let response = try await semanticRequest("textDocument/implementation", scriptID: scriptID) { uri in
            try Self.locationParameters(uri: uri, position: position)
        }
        return ScriptLanguageReplies.parseDefinition(response.payload).map { location in
            ScriptDefinitionLocation(documentURI: location.documentURI,
                                     scriptID: response.context.document(for: location.documentURI)?.scriptID, span: location.span)
        }
    }

    /// Types the type declared at `position` inherits from or conforms to.
    /// Falls back to the declaration's inheritance clause, resolved name by
    /// name, when the index has no hierarchy for types from binary modules.
    public func supertypes(scriptID: String, at position: ScriptLanguagePosition) async throws -> [ScriptDefinitionLocation] {
        let hierarchy = try await typeHierarchy("typeHierarchy/supertypes", scriptID: scriptID, at: position)
        guard hierarchy.isEmpty, let text = currentText(scriptID: scriptID) else { return hierarchy }
        var found: [ScriptDefinitionLocation] = []
        for name in ScriptInheritanceClause.typePositions(in: text, declarationAt: position) {
            if let location = try await definition(scriptID: scriptID, at: name).first { found.append(location) }
        }
        return found
    }

    /// Subclasses of a class and conformers of a protocol.
    public func subtypes(scriptID: String, at position: ScriptLanguagePosition) async throws -> [ScriptDefinitionLocation] {
        try await typeHierarchy("typeHierarchy/subtypes", scriptID: scriptID, at: position)
    }

    /// The protocol is two steps: prepare names the item, then a second request
    /// walks one level from it. Each item's selection range is its name.
    private func typeHierarchy(_ method: String, scriptID: String,
                               at position: ScriptLanguagePosition) async throws -> [ScriptDefinitionLocation] {
        let prepared = try await semanticRequest("textDocument/prepareTypeHierarchy", scriptID: scriptID) { uri in
            try Self.locationParameters(uri: uri, position: position)
        }
        guard let data = prepared.payload,
              let items = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [[String: Any]],
              let item = items.first else { return [] }
        let payload = try await resolveSemanticRequest(method, params: LSPJSON.data(["item": item]), context: prepared.context)
        guard let payload,
              let related = try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]) as? [[String: Any]] else { return [] }
        return related.compactMap { item in
            guard let uri = item["uri"] as? String,
                  let span = ScriptLanguageReplies.parseSpan(item["selectionRange"] ?? item["range"]) else { return nil }
            return ScriptDefinitionLocation(documentURI: uri, scriptID: prepared.context.document(for: uri)?.scriptID, span: span)
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

    /// Every place in the document that names the symbol at `position`.
    public func documentHighlights(scriptID: String, at position: ScriptLanguagePosition) async throws -> [ScriptLanguageSpan] {
        let response = try await semanticRequest("textDocument/documentHighlight", scriptID: scriptID) { uri in
            try Self.locationParameters(uri: uri, position: position)
        }
        guard let data = response.payload,
              let values = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [[String: Any]] else { return [] }
        return values.prefix(1_000).compactMap { ScriptLanguageReplies.parseSpan($0["range"]) }
    }

    public func documentSymbols(scriptID: String) async throws -> [ScriptDocumentSymbol] {
        let response = try await semanticRequest("textDocument/documentSymbol", scriptID: scriptID) { uri in
            try LSPJSON.data(["textDocument": ["uri": uri]])
        }
        return ScriptAssistanceReplies.symbols(response.payload)
    }

    /// Formats the document, or only `range` when one is given.
    public func formatting(scriptID: String, range: ScriptLanguageSpan? = nil,
                           tabSize: Int = 4, insertSpaces: Bool = true) async throws -> ScriptWorkspaceEdit {
        let method = range == nil ? "textDocument/formatting" : "textDocument/rangeFormatting"
        let response = try await semanticRequest(method, scriptID: scriptID) { uri in
            var parameters: [String: Any] = ["textDocument": ["uri": uri],
                                             "options": ["tabSize": max(1, min(tabSize, 16)), "insertSpaces": insertSpaces]]
            if let range { parameters["range"] = Self.rangeParameters(range) }
            return try LSPJSON.data(parameters)
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
