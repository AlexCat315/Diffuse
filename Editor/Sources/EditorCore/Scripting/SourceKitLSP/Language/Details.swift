public import Foundation

public enum ScriptAnalysisHealth: Sendable, Equatable {
    case checking
    case healthy
    case degraded(String)
}

public struct ScriptIndexProgress: Sendable, Equatable {
    public let title: String
    public let message: String?
    public let percentage: Int?
}

public struct ScriptLanguageLogEntry: Sendable, Equatable, Identifiable {
    public enum Level: String, Sendable { case debug, info, warning, error }
    public let id: UInt64
    public let date: Date
    public let level: Level
    public let message: String
}

public struct ScriptLanguageServiceDetails: Sendable, Equatable {
    public internal(set) var revision: UInt64 = 0
    public internal(set) var health: ScriptAnalysisHealth = .checking
    public internal(set) var indexing: ScriptIndexProgress?
    public internal(set) var logs: [ScriptLanguageLogEntry] = []
    public internal(set) var residentMemoryBytes: UInt64?
    public let executablePath: String

    public init(executablePath: String) { self.executablePath = executablePath }

    mutating func record(_ message: String, level: ScriptLanguageLogEntry.Level = .info) {
        revision &+= 1
        logs.append(ScriptLanguageLogEntry(id: revision, date: Date(), level: level, message: String(message.prefix(8_192))))
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }
}

enum ScriptLanguageSemanticEvidence {
    static func confirmsAnalysis(method: String, payload: Data?) -> Bool {
        switch method {
        case "textDocument/hover":
            return ScriptLanguageReplies.parseHover(payload).map { !$0.isEmpty } ?? false
        case "textDocument/completion":
            return !ScriptLanguageReplies.parseCompletion(payload).items.isEmpty
        case "textDocument/definition", "textDocument/references":
            return !ScriptLanguageReplies.parseDefinition(payload).isEmpty
        case "textDocument/signatureHelp":
            return ScriptAssistanceReplies.signatures(payload) != nil
        default:
            return false
        }
    }
}
