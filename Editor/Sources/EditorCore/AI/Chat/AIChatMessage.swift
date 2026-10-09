import Foundation

public struct AIChatMessage: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case user
        case assistant
    }

    public enum AssistantState: Sendable, Equatable {
        case thinking
        case streaming(String)
        case replied(String)
        case pendingConfirmation(summary: String)
        case applied(summary: String)
        case discarded
        case failed(String)
    }

    public var id: String
    public var role: Role
    public var text: String
    public var assistantState: AssistantState?

    public init(id: String = UUID().uuidString,
                role: Role,
                text: String,
                assistantState: AssistantState? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.assistantState = assistantState
    }
}
