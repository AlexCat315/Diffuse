import Foundation
import IntentRuntime

public enum SessionError: Error, CustomStringConvertible, Sendable {
    case unsupportedSignal(String)
    case httpError(statusCode: Int, body: String?)
    case malformedResponse(detail: String)
    case noPlanInResponse
    case planDecodingFailed(detail: String)

    public var description: String {
        switch self {
        case let .unsupportedSignal(kind):
            return "Session: signal '\(kind)' not yet handled"
        case let .httpError(code, body):
            return "Session inference HTTP \(code): \(body ?? "(no body)")"
        case let .malformedResponse(detail):
            return "Session: malformed response — \(detail)"
        case .noPlanInResponse:
            return "Session: model did not return a plan"
        case let .planDecodingFailed(detail):
            return "Session: plan decoding failed — \(detail)"
        }
    }
}

/// Per-project persistent AI participant.
///
/// Session maintains WorldView (incremental scene understanding) and
/// ConversationHistory (multi-turn context). It receives Signals, runs inference,
/// and produces Proposals. Inference is built-in — Session is the AI, not a
/// dispatcher to an external backend.
///
/// Phase 2: NaturalLanguage signals trigger inference; other modalities update
///          WorldView only. Phase 3 adds full multi-turn history to the API call.
public actor Session {
    public let id: String
    public private(set) var worldView: WorldView
    private var conversationHistory: [ConversationTurn]
    private let config: SessionConfig
    private let urlSession: URLSession
    private let maxHistoryTurns: Int

    private static let inferenceEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    public init(id: String = UUID().uuidString,
                config: SessionConfig,
                urlSession: URLSession = .shared,
                maxHistoryTurns: Int = 40) {
        self.id = id
        self.config = config
        self.urlSession = urlSession
        self.worldView = WorldView()
        self.conversationHistory = []
        self.maxHistoryTurns = maxHistoryTurns
    }

    // MARK: - Signal processing

    /// Runs inference on a NaturalLanguage signal and returns a Proposal.
    /// Use `observe()` for state-update signals; use `learn()` for UserCorrection.
    public func process(_ signal: Signal) async throws -> Proposal {
        guard case let .naturalLanguage(text, _) = signal else {
            throw SessionError.unsupportedSignal(signal.kind)
        }
        recordTurn(ConversationTurn(role: .user, content: text))
        let proposal = try await infer(userRequest: text)
        recordTurn(ConversationTurn(role: .assistant,
                                    content: proposal.plan.summary,
                                    proposalID: proposal.id))
        return proposal
    }

    // MARK: - Learning

    /// Records a UserCorrection — called when the user accepts, rejects, or modifies a Proposal.
    ///
    /// Phase 3: records outcome in ConversationHistory so the next request has correction context.
    /// Phase 4+: triggers preference learning / fine-tuning update.
    public func learn(proposalID: String, acceptedStepIDs: [String], rejectedStepIDs: [String]) {
        let note: String
        if rejectedStepIDs.isEmpty {
            note = "proposal \(proposalID) accepted (\(acceptedStepIDs.count) steps)"
        } else if acceptedStepIDs.isEmpty {
            note = "proposal \(proposalID) rejected (\(rejectedStepIDs.count) steps)"
        } else {
            let total = acceptedStepIDs.count + rejectedStepIDs.count
            note = "proposal \(proposalID) partially accepted (\(acceptedStepIDs.count)/\(total) steps)"
        }
        recordTurn(ConversationTurn(role: .assistant, content: note))
    }

    // MARK: - WorldView observation

    /// Seeds the entity index from a full snapshot. Call once at session creation;
    /// ongoing changes arrive as WorldEvents via observe(event:).
    public func observe(snapshot: SceneSemanticSnapshot) {
        worldView.apply(snapshot: snapshot)
    }

    /// Applies a fine-grained WorldEvent to the entity index (Phase 5 delta path).
    public func observe(event: WorldEvent) {
        worldView.apply(event: event)
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

    // MARK: - Inference

    private func infer(userRequest: String) async throws -> Proposal {
        let body = requestBody(userRequest: userRequest)
        let data = try await post(body)
        let plan = try parsePlan(from: data)
        return Proposal(
            sessionID: id,
            semanticIntent: userRequest,
            plan: plan,
            baseSceneRevision: worldView.sceneRevision,
            reasoning: plan.reasoning,
            confidence: 0.85,
            approvalPolicy: .requiresApproval
        )
    }

    private func requestBody(userRequest: String) -> [String: Any] {
        [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "system": systemPrompt(),
            "tools": [EditPlanTool.definition()],
            "tool_choice": ["type": "any"],
            "messages": [["role": "user", "content": userRequest]],
        ]
    }

    private func systemPrompt() -> String {
        var parts: [String] = []

        parts.append("""
        You are the AI scene-editing core of Guava, a native real-time game and cinematic engine.
        Translate the user's natural-language request into a structured scene edit plan \
        by calling the `execute_edit_plan` tool. Always call the tool — never respond with plain text.
        """)

        parts.append("Scene entities (JSON):\n\(entityIndexJSON())")

        if !worldView.recentEdits.isEmpty {
            let lines = worldView.recentEdits.suffix(10)
                .map { "- \($0.summary) (rev \($0.revision))" }
                .joined(separator: "\n")
            parts.append("Recent edits (most recent last):\n\(lines)")
        }

        if !worldView.selectedEntityRefs.isEmpty {
            parts.append("Currently selected: \(worldView.selectedEntityRefs.joined(separator: ", "))")
        }

        parts.append("""
        Rules:
        - Only operate on entities that exist in the scene entities list above.
        - Use the exact entity IDs from the list (format: "scene:<number>").
        - Prefer minimal plans — only include steps necessary to satisfy the request.
        - For set_transform, read the current position from the entity list and only change what the user asked for.
        - For snap_to_ground, set Y position to 0.
        """)

        return parts.joined(separator: "\n\n")
    }

    private func entityIndexJSON() -> String {
        guard !worldView.entityIndex.isEmpty else { return "[]" }
        let entities = worldView.entityIndex.values.sorted { $0.ref < $1.ref }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entities),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }

    // MARK: - HTTP

    private func post(_ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: Self.inferenceEndpoint,
                                 timeoutInterval: config.timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SessionError.httpError(statusCode: http.statusCode,
                                         body: String(data: data, encoding: .utf8))
        }
        return data
    }

    // MARK: - Response parsing

    private func parsePlan(from data: Data) throws -> SceneEditPlan {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionError.malformedResponse(detail: "top-level JSON is not an object")
        }
        guard let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { $0["type"] as? String == "tool_use" }),
              let toolInput = toolUse["input"] as? [String: Any]
        else {
            throw SessionError.noPlanInResponse
        }
        guard let planData = try? JSONSerialization.data(withJSONObject: toolInput) else {
            throw SessionError.planDecodingFailed(detail: "could not re-serialize tool input")
        }
        do {
            return try JSONDecoder().decode(SceneEditPlan.self, from: planData)
        } catch {
            throw SessionError.planDecodingFailed(detail: String(describing: error))
        }
    }

    // MARK: - History

    private func recordTurn(_ turn: ConversationTurn) {
        conversationHistory.append(turn)
        if conversationHistory.count > maxHistoryTurns {
            conversationHistory.removeFirst(conversationHistory.count - maxHistoryTurns)
        }
    }
}
