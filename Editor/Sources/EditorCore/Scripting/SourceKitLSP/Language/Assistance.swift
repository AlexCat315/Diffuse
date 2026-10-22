public struct ScriptSignatureParameter: Sendable, Equatable {
    public let label: String
    public let documentation: String?
}

public struct ScriptSignatureInformation: Sendable, Equatable {
    public let label: String
    public let documentation: String?
    public let parameters: [ScriptSignatureParameter]
}

public struct ScriptSignatureHelp: Sendable, Equatable {
    public let signatures: [ScriptSignatureInformation]
    public let activeSignature: Int
    public let activeParameter: Int?
}

public struct ScriptDocumentSymbol: Sendable, Equatable {
    public let name: String
    public let detail: String?
    public let kind: Int
    public let range: ScriptLanguageSpan
    public let selectionRange: ScriptLanguageSpan
    public let children: [ScriptDocumentSymbol]
}

/// A declaration anywhere in the indexed workspace.
public struct ScriptWorkspaceSymbol: Sendable, Equatable {
    public let name: String
    public let kind: Int
    public let containerName: String?
    public let location: ScriptDefinitionLocation
}
