import Foundation

public enum SessionError: Error, CustomStringConvertible, Sendable {
    case unsupportedSignal(String)
    case backendUnavailable

    public var description: String {
        switch self {
        case let .unsupportedSignal(kind):
            return "Session: signal '\(kind)' not yet handled"
        case .backendUnavailable:
            return "Session: no backend configured"
        }
    }
}

/// Per-project persistent AI participant.
///
/// Session is stateful: it maintains a WorldView (incremental scene understanding)
/// and a ConversationHistory (multi-turn context). It receives Signals and produces
/// Proposals via its SessionBackend.
///
/// Phase 2: WorldView is snapshot-based. Phase 5 migrates to delta-driven.
/// Phase 2: NaturalLanguage signals are handled; other modalities are accepted
///          via observe() for WorldView bookkeeping but not yet passed to the backend.
public actor Session {
    public let id: String
    public private(set) var worldView: WorldView
    private var conversationHistory: [ConversationTurn]
    private let backend: any SessionBackend
    private let maxHistoryTurns: Int

    public init(id: String = UUID().uuidString,
                backend: any SessionBackend,
                maxHistoryTurns: Int = 40) {
        self.id = id
        self.worldView = WorldView()
        self.conversationHistory = []
        self.backend = backend
        self.maxHistoryTurns = maxHistoryTurns
    }

    // MARK: - Signal processing

    /// Processes a Signal and returns a Proposal.
    /// For non-NL signals, the session updates its WorldView and returns nil.
    /// Only NaturalLanguage signals produce a Proposal in Phase 2.
    public func process(_ signal: Signal) async throws -> Proposal {
        switch signal {
        case let .naturalLanguage(text, _):
            recordTurn(ConversationTurn(role: .user, content: text))
        case let .selectionChanged(refs):
            worldView.apply(selectionChanged: refs)
        case let .worldChanged(summary, revision):
            worldView.apply(editSummary: summary, revision: revision)
        case .userCorrection:
            break
        }

        let proposal = try await backend.generateProposal(
            signal: signal,
            worldView: worldView,
            history: conversationHistory,
            sessionID: id
        )
        recordTurn(ConversationTurn(role: .assistant,
                                    content: proposal.plan.summary,
                                    proposalID: proposal.id))
        return proposal
    }

    // MARK: - WorldView observation (fire-and-forget, no Proposal produced)

    public func observe(snapshot: SceneSemanticSnapshot) {
        worldView.apply(snapshot: snapshot)
    }

    public func observe(editSummary: String, revision: UInt64) {
        worldView.apply(editSummary: editSummary, revision: revision)
    }

    public func observe(selectionChanged entityRefs: [String]) {
        worldView.apply(selectionChanged: entityRefs)
    }

    // MARK: - History

    public func clearHistory() {
        conversationHistory.removeAll()
    }

    public func historySnapshot() -> [ConversationTurn] {
        conversationHistory
    }

    // MARK: - Private

    private func recordTurn(_ turn: ConversationTurn) {
        conversationHistory.append(turn)
        if conversationHistory.count > maxHistoryTurns {
            conversationHistory.removeFirst(conversationHistory.count - maxHistoryTurns)
        }
    }
}
