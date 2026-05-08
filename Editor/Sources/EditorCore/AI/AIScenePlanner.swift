import Foundation
import AIRuntime

public struct AIScenePlannerConfig: Sendable {
    public var apiKey: String
    public var model: String
    public var maxTokens: Int
    public var timeoutInterval: TimeInterval

    public static let defaultModel = "claude-sonnet-4-6"

    public init(apiKey: String,
                model: String = defaultModel,
                maxTokens: Int = 2048,
                timeoutInterval: TimeInterval = 30) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.timeoutInterval = timeoutInterval
    }
}

public enum AIScenePlannerError: Error, CustomStringConvertible, Sendable {
    case httpError(statusCode: Int, body: String?)
    case malformedResponse(detail: String)
    case noToolUseInResponse
    case planDecodingFailed(detail: String)

    public var description: String {
        switch self {
        case let .httpError(code, body):
            return "AI scene planner HTTP \(code): \(body ?? "(no body)")"
        case let .malformedResponse(detail):
            return "Malformed AI response: \(detail)"
        case .noToolUseInResponse:
            return "Model did not call execute_edit_plan"
        case let .planDecodingFailed(detail):
            return "Failed to decode edit plan: \(detail)"
        }
    }
}

/// Generates a multi-step `SceneEditPlan` from a natural-language request and a scene snapshot.
///
/// Calls the Anthropic Messages API with a single `execute_edit_plan` tool. Claude receives
/// the full serialized scene state and produces a fully-typed, structured plan. Callers then
/// use `SceneEditPlanExecutor` to convert the plan into a `TransactionIR` for execution.
public struct AIScenePlanner: Sendable {
    private let config: AIScenePlannerConfig
    private let session: URLSession

    private static let apiEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let anthropicVersion = "2023-06-01"

    public var modelID: String { config.model }

    public init(config: AIScenePlannerConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Generates a `SceneEditPlan` for `userRequest` given the current scene state.
    ///
    /// - Parameters:
    ///   - userRequest: Free-form user intent text.
    ///   - snapshot: Semantic snapshot of the live scene, produced by `SceneSemanticEncoder`.
    public func plan(userRequest: String,
                     snapshot: SceneSemanticSnapshot) async throws -> SceneEditPlan {
        let snapshotJSON = encodeSnapshot(snapshot)
        let body = makeRequestBody(userRequest: userRequest, snapshotJSON: snapshotJSON)
        let data = try await post(body)
        return try parsePlan(from: data)
    }

    // MARK: - Request construction

    private func makeRequestBody(userRequest: String,
                                 snapshotJSON: String) -> [String: Any] {
        [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "system": systemPrompt(snapshotJSON: snapshotJSON),
            "tools": [editPlanTool()],
            "tool_choice": ["type": "any"],
            "messages": [
                ["role": "user", "content": userRequest]
            ],
        ]
    }

    private func systemPrompt(snapshotJSON: String) -> String {
        """
        You are the AI scene-editing core of Guava, a native real-time game and cinematic engine.

        The user has issued a natural-language request. Translate it into a structured, \
        multi-step scene edit plan by calling the `execute_edit_plan` tool. \
        Always call the tool — never respond with plain text.

        Scene state (JSON):
        \(snapshotJSON)

        Rules:
        - Only operate on entities that exist in the scene snapshot above.
        - Use the exact entity IDs from the snapshot (format: "scene:<number>").
        - Prefer minimal plans — only include steps necessary to satisfy the request.
        - For set_transform, read the current values from the snapshot and only change \
        what the user asked for.
        - For snap_to_ground, set Y position to 0.
        - Group related mutations into one plan with a clear one-line summary.
        """
    }

    private func editPlanTool() -> [String: Any] {
        EditPlanTool.definition()
    }

    // MARK: - Snapshot serialisation

    private func encodeSnapshot(_ snapshot: SceneSemanticSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot),
              let str = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return str
    }

    // MARK: - HTTP

    private func post(_ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: Self.apiEndpoint, timeoutInterval: config.timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIScenePlannerError.httpError(statusCode: http.statusCode,
                                                body: String(data: data, encoding: .utf8))
        }
        return data
    }

    // MARK: - Response parsing

    private func parsePlan(from data: Data) throws -> SceneEditPlan {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIScenePlannerError.malformedResponse(detail: "top-level JSON is not an object")
        }
        guard let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { $0["type"] as? String == "tool_use" }),
              let toolInput = toolUse["input"] as? [String: Any]
        else {
            throw AIScenePlannerError.noToolUseInResponse
        }
        guard let planData = try? JSONSerialization.data(withJSONObject: toolInput) else {
            throw AIScenePlannerError.planDecodingFailed(detail: "could not re-serialize tool input")
        }
        do {
            return try JSONDecoder().decode(SceneEditPlan.self, from: planData)
        } catch {
            throw AIScenePlannerError.planDecodingFailed(detail: String(describing: error))
        }
    }
}
