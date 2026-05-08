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

    private static let anthropicAPIVersion = "2023-06-01"

    private var inferenceEndpoint: URL {
        switch config.apiFormat {
        case .anthropic:
            return config.baseURL.appendingPathComponent("v1/messages")
        case .openAICompatible:
            return config.baseURL.appendingPathComponent("v1/chat/completions")
        }
    }

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
    /// Appended as a `.user` turn so the next inference call sees the correction in context.
    /// Phase 4+: triggers preference learning / fine-tuning update.
    public func learn(proposalID: String, acceptedStepIDs: [String], rejectedStepIDs: [String]) {
        let content: String
        if rejectedStepIDs.isEmpty {
            let n = acceptedStepIDs.count
            content = "I accepted your suggestion (\(n) step\(n == 1 ? "" : "s") applied)."
        } else if acceptedStepIDs.isEmpty {
            content = "I rejected your suggestion. Please try a different approach."
        } else {
            let total = acceptedStepIDs.count + rejectedStepIDs.count
            content = "I partially accepted your suggestion: \(acceptedStepIDs.count) of \(total) steps applied; \(rejectedStepIDs.count) rejected."
        }
        recordTurn(ConversationTurn(role: .user, content: content, proposalID: proposalID))
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
        switch config.apiFormat {
        case .anthropic:
            return [
                "model": config.model,
                "max_tokens": config.maxTokens,
                "system": systemPrompt(),
                "tools": [EditPlanTool.definition()],
                "tool_choice": ["type": "any"],
                "messages": [["role": "user", "content": userRequest]],
            ]
        case .openAICompatible:
            return [
                "model": config.model,
                "max_tokens": config.maxTokens,
                "tools": [EditPlanTool.openAIDefinition()],
                "tool_choice": ["type": "function",
                                "function": ["name": "execute_edit_plan"]],
                "messages": [
                    ["role": "system", "content": systemPrompt()],
                    ["role": "user", "content": userRequest],
                ],
            ]
        }
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

        if !conversationHistory.isEmpty {
            let lines = conversationHistory.suffix(12).map { turn -> String in
                let label = turn.role == .user ? "User" : "Assistant"
                return "\(label): \(turn.content)"
            }.joined(separator: "\n")
            parts.append("Conversation so far (most recent last):\n\(lines)")
        }

        parts.append("""
        Rules:
        - Only operate on entities that exist in the scene entities list above.
        - Use the exact entity IDs from the list (format: "scene:<number>").
        - Prefer minimal plans — only include steps necessary to satisfy the request.
        - For set_transform, use the `position` field (local space) as the base and only change \
        what the user asked for. When an entity is in a hierarchy, `evaluated.worldPosition` \
        shows its actual world-space position — use it for spatial reasoning but set_transform \
        always writes local space.
        - For snap_to_ground, set Y position to 0.
        - If the conversation history shows a correction (e.g. "I rejected your suggestion"), \
        adjust your approach accordingly before proposing again.
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
        var request = URLRequest(url: inferenceEndpoint,
                                 timeoutInterval: config.timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch config.apiFormat {
        case .anthropic:
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        case .openAICompatible:
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
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
        switch config.apiFormat {
        case .anthropic:
            return try parseAnthropicPlan(from: data)
        case .openAICompatible:
            return try parseOpenAIPlan(from: data)
        }
    }

    private func parseAnthropicPlan(from data: Data) throws -> SceneEditPlan {
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

    private func parseOpenAIPlan(from data: Data) throws -> SceneEditPlan {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let toolCalls = message["tool_calls"] as? [[String: Any]],
              let firstCall = toolCalls.first(where: { $0["type"] as? String == "function" }),
              let function = firstCall["function"] as? [String: Any],
              let argumentsString = function["arguments"] as? String
        else {
            throw SessionError.noPlanInResponse
        }
        guard let planData = argumentsString.data(using: .utf8) else {
            throw SessionError.planDecodingFailed(detail: "could not encode arguments as UTF-8")
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
