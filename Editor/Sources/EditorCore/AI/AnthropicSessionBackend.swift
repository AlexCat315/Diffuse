import Foundation
import AIRuntime
import IntentRuntime

public enum AnthropicSessionBackendError: Error, CustomStringConvertible, Sendable {
    case unsupportedSignal
    case httpError(statusCode: Int, body: String?)
    case malformedResponse(detail: String)
    case noToolUseInResponse
    case planDecodingFailed(detail: String)

    public var description: String {
        switch self {
        case .unsupportedSignal:
            return "AnthropicSessionBackend: only NaturalLanguage signals are supported in Phase 2"
        case let .httpError(code, body):
            return "AnthropicSessionBackend HTTP \(code): \(body ?? "(no body)")"
        case let .malformedResponse(detail):
            return "Malformed response: \(detail)"
        case .noToolUseInResponse:
            return "Model did not call execute_edit_plan"
        case let .planDecodingFailed(detail):
            return "Plan decoding failed: \(detail)"
        }
    }
}

/// Anthropic-backed SessionBackend.
///
/// Replaces AIScenePlanner with a richer context: WorldView includes recent edits
/// and selection, enabling multi-request awareness within a project session.
///
/// Phase 2: single-turn per request. Phase 3+ adds full multi-turn history.
public struct AnthropicSessionBackend: SessionBackend {
    private let config: AIScenePlannerConfig
    private let urlSession: URLSession

    private static let apiEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let anthropicVersion = "2023-06-01"

    public init(config: AIScenePlannerConfig, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    // MARK: - SessionBackend

    public func generateProposal(signal: Signal,
                                  worldView: WorldView,
                                  history: [ConversationTurn],
                                  sessionID: String) async throws -> Proposal {
        guard case let .naturalLanguage(text, _) = signal else {
            throw AnthropicSessionBackendError.unsupportedSignal
        }

        let snapshotJSON = worldView.sceneSnapshot.map(encodeSnapshot) ?? "{}"
        let body = makeRequestBody(userRequest: text, snapshotJSON: snapshotJSON, worldView: worldView)
        let data = try await post(body)
        let plan = try parsePlan(from: data)

        return Proposal(
            sessionID: sessionID,
            semanticIntent: text,
            plan: plan,
            baseSceneRevision: worldView.sceneRevision,
            reasoning: plan.reasoning,
            confidence: 0.85,
            approvalPolicy: .requiresApproval
        )
    }

    // MARK: - Request construction

    private func makeRequestBody(userRequest: String,
                                 snapshotJSON: String,
                                 worldView: WorldView) -> [String: Any] {
        [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "system": systemPrompt(snapshotJSON: snapshotJSON, worldView: worldView),
            "tools": [AnthropicEditPlanTool.definition()],
            "tool_choice": ["type": "any"],
            "messages": [["role": "user", "content": userRequest]],
        ]
    }

    private func systemPrompt(snapshotJSON: String, worldView: WorldView) -> String {
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
        var request = URLRequest(url: Self.apiEndpoint, timeoutInterval: config.timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AnthropicSessionBackendError.httpError(statusCode: http.statusCode,
                                                         body: String(data: data, encoding: .utf8))
        }
        return data
    }

    // MARK: - Response parsing

    private func parsePlan(from data: Data) throws -> SceneEditPlan {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicSessionBackendError.malformedResponse(detail: "top-level JSON is not an object")
        }
        guard let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { $0["type"] as? String == "tool_use" }),
              let toolInput = toolUse["input"] as? [String: Any]
        else {
            throw AnthropicSessionBackendError.noToolUseInResponse
        }
        guard let planData = try? JSONSerialization.data(withJSONObject: toolInput) else {
            throw AnthropicSessionBackendError.planDecodingFailed(detail: "could not re-serialize tool input")
        }
        do {
            return try JSONDecoder().decode(SceneEditPlan.self, from: planData)
        } catch {
            throw AnthropicSessionBackendError.planDecodingFailed(detail: String(describing: error))
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
}
