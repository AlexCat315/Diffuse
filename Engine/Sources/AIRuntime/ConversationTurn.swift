import Foundation

public enum TurnRole: String, Sendable, Codable {
    case user
    case assistant
}

/// One turn in Session's conversation history.
/// Codable so it can be persisted across editor restarts in Phase 3+.
public struct ConversationTurn: Sendable, Codable {
    public var role: TurnRole
    public var content: String
    public var timestamp: Date
    public var proposalID: String?

    public init(role: TurnRole,
                content: String,
                timestamp: Date = Date(),
                proposalID: String? = nil) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.proposalID = proposalID
    }
}
