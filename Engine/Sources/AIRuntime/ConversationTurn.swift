import Foundation

public enum ConversationTurnKind: Sendable, Codable {
    case userText(String)
    case assistantToolCall(toolUseID: String, name: String, inputJSON: String)
    case toolResult(toolUseID: String, content: String)
}

public struct ConversationTurn: Sendable, Codable {
    public var kind: ConversationTurnKind
    public var timestamp: Date
    public var proposalID: String?

    public init(kind: ConversationTurnKind,
                timestamp: Date = Date(),
                proposalID: String? = nil) {
        self.kind = kind
        self.timestamp = timestamp
        self.proposalID = proposalID
    }
}
