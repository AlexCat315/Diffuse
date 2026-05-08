import Foundation

/// The AI inference backend for a Session.
///
/// Concrete implementations live in EditorCore (network access, API keys).
/// AIRuntime holds only the protocol, keeping the engine module network-free.
public protocol SessionBackend: Sendable {
    func generateProposal(
        signal: Signal,
        worldView: WorldView,
        history: [ConversationTurn],
        sessionID: String
    ) async throws -> Proposal
}
