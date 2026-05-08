import Foundation

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

    /// Processes a Signal. NaturalLanguage signals trigger inference and return a Proposal.
    /// Other signals update WorldView state and return nil when inference is not needed.
    public func process(_ signal: Signal) async throws -> Proposal {
        switch signal {
        case let .naturalLanguage(text, _):
            recordTurn(ConversationTurn(role: .user, content: text))
            let proposal = try await infer(userRequest: text)
            recordTurn(ConversationTurn(role: .assistant,
                                        content: proposal.plan.summary,
                                        proposalID: proposal.id))
            return proposal
        case let .selectionChanged(refs):
            worldView.apply(selectionChanged: refs)
        case let .worldChanged(summary, revision):
            worldView.apply(editSummary: summary, revision: revision)
        case .userCorrection:
            break
        }
        throw SessionError.unsupportedSignal("non-NL signal does not produce a Proposal in Phase 2")
    }

    // MARK: - WorldView observation

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

    // MARK: - Inference

    private func infer(userRequest: String) async throws -> Proposal {
        let snapshotJSON = worldView.sceneSnapshot.map(encodeSnapshot) ?? "{}"
        let body = requestBody(userRequest: userRequest, snapshotJSON: snapshotJSON)
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

    private func requestBody(userRequest: String, snapshotJSON: String) -> [String: Any] {
        [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "system": systemPrompt(snapshotJSON: snapshotJSON),
            "tools": [EditPlanTool.definition()],
            "tool_choice": ["type": "any"],
            "messages": [["role": "user", "content": userRequest]],
        ]
    }

    private func systemPrompt(snapshotJSON: String) -> String {
        var parts: [String] = []

        parts.append("""
        You are the AI scene-editing core of Guava, a native real-time game and cinematic engine.
        Translate the user's natural-language request into a structured scene edit plan \
        by calling the `execute_edit_plan` tool. Always call the tool — never respond with plain text.
        """)

        parts.append("Scene state (JSON):\n\(snapshotJSON)")

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
        - Only operate on entities that exist in the scene snapshot above.
        - Use the exact entity IDs from the snapshot (format: "scene:<number>").
        - Prefer minimal plans — only include steps necessary to satisfy the request.
        - For set_transform, read the current values from the snapshot and only change what the user asked for.
        - For snap_to_ground, set Y position to 0.
        """)

        return parts.joined(separator: "\n\n")
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

    // MARK: - Snapshot serialisation

    private func encodeSnapshot(_ snapshot: SceneSemanticSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    // MARK: - History

    private func recordTurn(_ turn: ConversationTurn) {
        conversationHistory.append(turn)
        if conversationHistory.count > maxHistoryTurns {
            conversationHistory.removeFirst(conversationHistory.count - maxHistoryTurns)
        }
    }
}
