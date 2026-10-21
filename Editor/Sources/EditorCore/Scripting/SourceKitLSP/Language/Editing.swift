import Foundation

public struct ScriptWorkspaceEdit: Sendable, Equatable {
    public let documents: [ScriptDocumentEdit]

    public init(documents: [ScriptDocumentEdit]) { self.documents = documents }
    public var isEmpty: Bool { documents.allSatisfy { $0.edits.isEmpty } }
}

public struct ScriptDocumentEdit: Sendable, Equatable {
    public let scriptID: String
    public let sourceRevision: UInt64
    public let edits: [ScriptCompletionTextEdit]

    public init(scriptID: String, sourceRevision: UInt64, edits: [ScriptCompletionTextEdit]) {
        self.scriptID = scriptID
        self.sourceRevision = sourceRevision
        self.edits = edits
    }
}

public struct ScriptRenamePreparation: Sendable, Equatable {
    public let range: ScriptLanguageSpan
    public let placeholder: String?
}

public struct ScriptCodeAction: Sendable, Equatable, Identifiable {
    public let title: String
    public let kind: String?
    public let isPreferred: Bool
    public let disabledReason: String?
    public let edit: ScriptWorkspaceEdit?
    public var needsResolution: Bool { edit == nil && disabledReason == nil && resolution != nil }
    public var id: String { title + "|" + (kind ?? "") }
    let resolution: Data?
    let context: ScriptSemanticContext
}

public enum ScriptLanguageEditError: Error, LocalizedError, Sendable, Equatable {
    case malformedReply
    case externalDocument(String)
    case unsupportedResourceOperation
    case staleDocument(String)
    case unsupportedCommand
    case invalidRange
    case overlappingEdits
    case duplicateDocument
    case noHistory
    case disabledAction(String)

    public var errorDescription: String? {
        switch self {
        case .malformedReply: "The language server returned an invalid edit."
        case let .externalDocument(uri): "The language server attempted to edit a file outside this script workspace: \(uri)"
        case .unsupportedResourceOperation: "Creating, moving, or deleting files through a language action is not supported."
        case let .staleDocument(identifier): "The script changed while the language action was running: \(identifier)"
        case .unsupportedCommand: "This language action requires a server command that cannot be applied safely."
        case .invalidRange: "The language server returned an invalid text range."
        case .overlappingEdits: "The language server returned overlapping text edits."
        case .duplicateDocument: "The language server returned multiple edit groups for the same document."
        case .noHistory: "There is no language operation to undo or redo."
        case let .disabledAction(reason): reason
        }
    }
}

struct ScriptSemanticContext: Sendable, Equatable {
    struct Document: Sendable, Equatable {
        let scriptID: String
        let revision: UInt64
        let version: Int
    }
    let documents: [String: Document]
    let generation: UUID

    init(documents: [String: Document], generation: UUID = UUID()) {
        self.documents = documents
        self.generation = generation
    }

    func document(for uri: String) -> Document? {
        documents[Self.documentKey(uri)]
    }

    static func documentKey(_ uri: String) -> String {
        guard let url = URL(string: uri), url.isFileURL else { return uri }
        return url.resolvingSymlinksInPath().standardizedFileURL.absoluteString
    }
}

struct ScriptSemanticResponse: Sendable {
    let payload: Data?
    let context: ScriptSemanticContext
}
