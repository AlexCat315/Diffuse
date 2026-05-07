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
        [
            "name": "execute_edit_plan",
            "description": "Execute a multi-step scene edit plan. Each step atomically mutates one aspect of the scene.",
            "input_schema": planSchema(),
        ]
    }

    private func planSchema() -> [String: Any] {
        let stepOps = SceneEditOp.allCases.map(\.rawValue)
        return [
            "type": "object",
            "required": ["summary", "steps"],
            "properties": [
                "summary": [
                    "type": "string",
                    "description": "One-line description of what the overall plan achieves.",
                ] as [String: Any],
                "reasoning": [
                    "type": "string",
                    "description": "Brief explanation of why these steps satisfy the request. Used for debugging.",
                ] as [String: Any],
                "steps": [
                    "type": "array",
                    "description": "Ordered list of atomic mutation steps to execute.",
                    "items": stepSchema(ops: stepOps),
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    private func stepSchema(ops: [String]) -> [String: Any] {
        [
            "type": "object",
            "required": ["op"],
            "properties": [
                "op": [
                    "type": "string", "enum": ops,
                    "description": "The mutation operation to perform.",
                ] as [String: Any],
                "entity_id": [
                    "type": "string",
                    "description": "Target entity in 'scene:<number>' format. Required for all ops except spawn_entity.",
                ] as [String: Any],
                "label": [
                    "type": "string",
                    "description": "Entity display name for spawn_entity.",
                ] as [String: Any],
                "spawn_position": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] world position for spawn_entity. Default [0, 0, 0].",
                ] as [String: Any],
                "position": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] world position in metres for set_transform.",
                ] as [String: Any],
                "euler_degrees": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] XYZ intrinsic Euler rotation in degrees for set_transform.",
                ] as [String: Any],
                "scale": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] scale factors for set_transform.",
                ] as [String: Any],
                "name": [
                    "type": "string",
                    "description": "New entity name for set_name.",
                ] as [String: Any],
                "light_type": [
                    "type": "string", "enum": ["directional", "point", "spot"],
                    "description": "Light type for set_light_type.",
                ] as [String: Any],
                "intensity": [
                    "type": "number",
                    "description": "Light intensity for set_light_intensity.",
                ] as [String: Any],
                "color": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[r, g, b] linear 0–1 colour for set_light_color.",
                ] as [String: Any],
                "range": [
                    "type": "number",
                    "description": "Light range in metres for set_light_range.",
                ] as [String: Any],
                "spot_inner_angle": [
                    "type": "number",
                    "description": "Spot cone inner angle in degrees for set_light_spot_angles.",
                ] as [String: Any],
                "spot_outer_angle": [
                    "type": "number",
                    "description": "Spot cone outer angle in degrees for set_light_spot_angles.",
                ] as [String: Any],
                "camera_target": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] look-at point for set_camera_pose.",
                ] as [String: Any],
                "camera_up": [
                    "type": "array", "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] up vector for set_camera_pose. Default [0, 1, 0].",
                ] as [String: Any],
                "motion_type": [
                    "type": "string", "enum": ["static", "dynamic", "kinematic"],
                    "description": "Rigid body motion type for set_rigidbody_motion.",
                ] as [String: Any],
                "mass": [
                    "type": "number",
                    "description": "Rigid body mass in kg for set_rigidbody_mass.",
                ] as [String: Any],
                "gravity_scale": [
                    "type": "number",
                    "description": "Gravity multiplier for set_rigidbody_gravity.",
                ] as [String: Any],
                "is_trigger": [
                    "type": "boolean",
                    "description": "Collider trigger flag for set_collider_trigger.",
                ] as [String: Any],
                "is_enabled": [
                    "type": "boolean",
                    "description": "Constraint enabled flag for set_constraint_enabled.",
                ] as [String: Any],
            ] as [String: Any],
        ]
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
