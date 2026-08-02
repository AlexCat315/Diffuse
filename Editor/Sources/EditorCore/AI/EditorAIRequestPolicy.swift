import Foundation

enum EditorAIRequestPolicy {
    static let pendingConfirmationMessage =
        "Resolve the pending confirmation before submitting another AI action."
    static let requestInFlightMessage =
        "Wait for the current AI request to finish before submitting another."

    static func rejectionMessage(hasPendingConfirmation: Bool,
                                 requestInFlight: Bool) -> String? {
        if hasPendingConfirmation { return pendingConfirmationMessage }
        if requestInFlight { return requestInFlightMessage }
        return nil
    }
}

enum EditorPlanSubmissionError: Error, LocalizedError, Equatable {
    case pendingConfirmation
    case lockedEntities([UInt64])

    var errorDescription: String? {
        switch self {
        case .pendingConfirmation:
            return EditorAIRequestPolicy.pendingConfirmationMessage
        case let .lockedEntities(entityIDs):
            let labels = entityIDs.sorted().map(String.init).joined(separator: ", ")
            return "The plan targets locked entities: \(labels). Unlock them before applying the action."
        }
    }
}
