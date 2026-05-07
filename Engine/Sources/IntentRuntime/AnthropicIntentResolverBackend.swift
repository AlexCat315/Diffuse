import CapabilityRuntime
import Foundation

// MARK: - Config

public struct AnthropicIntentResolverBackendConfig: Sendable {
    public var apiKey: String
    public var model: String
    public var maxTokens: Int

    public static let defaultModel = "claude-sonnet-4-6"

    public init(apiKey: String,
                model: String = defaultModel,
                maxTokens: Int = 1024) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
    }
}

// MARK: - Errors

public enum AnthropicIntentResolverBackendError: Error, CustomStringConvertible, Sendable {
    case httpError(statusCode: Int, body: String?)
    case malformedResponse(detail: String)
    case noCapabilitiesAvailable

    public var description: String {
        switch self {
        case let .httpError(code, body):
            return "Anthropic API HTTP \(code): \(body ?? "(no body)")"
        case let .malformedResponse(detail):
            return "Malformed Anthropic response: \(detail)"
        case .noCapabilitiesAvailable:
            return "No capabilities available for intent resolution"
        }
    }
}

// MARK: - Backend

/// `IntentResolverBackend` implementation backed by the Anthropic Messages API.
///
/// Each `CapabilitySymbolicView` is presented to the model as a tool definition.
/// The model picks the best match and returns a `tool_use` block that is decoded
/// into an `IntentIR`.
public struct AnthropicIntentResolverBackend: IntentResolverBackend {
    private let config: AnthropicIntentResolverBackendConfig
    private let session: URLSession

    private static let apiEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let anthropicVersion = "2023-06-01"

    public init(config: AnthropicIntentResolverBackendConfig,
                session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - IntentResolverBackend

    public func resolve(_ intent: NaturalLanguageIntent,
                        context: NaturalLanguageIntentContext,
                        capabilities: [CapabilitySymbolicView]) async throws -> IntentResolutionResult {
        guard !capabilities.isEmpty else {
            throw AnthropicIntentResolverBackendError.noCapabilitiesAvailable
        }

        let tools = capabilities.map(makeTool(from:))
        let body = makeRequestBody(intent: intent, context: context, tools: tools)
        let data = try await post(body)
        return try parseResponse(data, intent: intent, capabilities: capabilities)
    }

    // MARK: - Request construction

    private func makeRequestBody(intent: NaturalLanguageIntent,
                                 context: NaturalLanguageIntentContext,
                                 tools: [[String: Any]]) -> [String: Any] {
        [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "system": systemPrompt(context: context),
            "tools": tools,
            "tool_choice": ["type": "any"],
            "messages": [
                ["role": "user", "content": intent.text]
            ],
        ]
    }

    private func systemPrompt(context: NaturalLanguageIntentContext) -> String {
        var lines: [String] = [
            """
            You are the AI reasoning layer of Guava, a native real-time game and cinematic engine. \
            Your job is to translate the user's natural-language intent into exactly ONE engine capability \
            by calling the matching tool. Always call a tool — never respond with plain text. \
            Choose the most specific capability that matches. \
            Prefer lower-scope operations (scene_instance over asset) unless the user explicitly \
            requests a global or asset-level change.
            """,
        ]

        if !context.selectedObjectIDs.isEmpty {
            lines.append(
                "Currently selected object IDs: \(context.selectedObjectIDs.joined(separator: ", ")). " +
                "Use these as target_object_ids when the user says 'this', 'it', or 'the selected'."
            )
        } else {
            lines.append("No objects are currently selected.")
        }

        if let locale = context.localeIdentifier, !locale.isEmpty {
            lines.append("User locale: \(locale).")
        }

        return lines.joined(separator: "\n\n")
    }

    // MARK: - Tool schema generation

    private func makeTool(from view: CapabilitySymbolicView) -> [String: Any] {
        var desc = view.summary
        if view.confirmationPolicy.level != .auto {
            desc += " [requires confirmation: \(view.confirmationPolicy.level.rawValue)]"
        }
        if !view.reversible {
            desc += " [irreversible]"
        }

        return [
            "name": encodedToolName(view.verbID),
            "description": desc,
            "input_schema": inputSchema(for: view),
        ]
    }

    private func inputSchema(for view: CapabilitySymbolicView) -> [String: Any] {
        var properties: [String: Any] = [
            "target_object_ids": [
                "type": "array",
                "items": ["type": "string"],
                "description": "Stable IDs of the objects this operation targets. "
                    + "Pass selected object IDs when the user refers to 'this', 'it', or 'the selected one'.",
            ] as [String: Any],
        ]
        var required: [String] = []

        for arg in view.arguments {
            properties[arg.name] = argSchema(for: arg)
            if arg.required {
                required.append(arg.name)
            }
        }

        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }

    private func argSchema(for arg: CapabilitySymbolicArgument) -> [String: Any] {
        var hint = arg.llmHint ?? arg.description ?? arg.name
        if let unit = arg.unit { hint += " (unit: \(unit))" }

        if !arg.enumChoices.isEmpty {
            return ["type": "string", "enum": arg.enumChoices, "description": hint]
        }

        switch arg.typeID {
        case "bool":
            return ["type": "boolean", "description": hint]
        case "i32":
            return ["type": "integer", "description": hint]
        case "f32":
            return ["type": "number", "description": hint]
        case "string", "doc_uri":
            return ["type": "string", "description": hint]
        case "stable_id":
            return ["type": "string", "description": "Stable entity ID — \(hint)"]
        case "vec3":
            return vec3Schema(description: hint)
        case "transform":
            return [
                "type": "object",
                "description": hint,
                "properties": [
                    "position": vec3Schema(description: "World position"),
                    "rotation_euler": vec3Schema(description: "Euler angles in degrees"),
                    "scale": vec3Schema(description: "Scale factors"),
                ] as [String: Any],
            ]
        default:
            return ["type": "string", "description": hint]
        }
    }

    private func vec3Schema(description: String) -> [String: Any] {
        [
            "type": "object",
            "description": description,
            "properties": [
                "x": ["type": "number"] as [String: Any],
                "y": ["type": "number"] as [String: Any],
                "z": ["type": "number"] as [String: Any],
            ],
            "required": ["x", "y", "z"],
        ]
    }

    // MARK: - HTTP

    private func post(_ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: Self.apiEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AnthropicIntentResolverBackendError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }
        return data
    }

    // MARK: - Response parsing

    private func parseResponse(_ data: Data,
                                intent: NaturalLanguageIntent,
                                capabilities: [CapabilitySymbolicView]) throws -> IntentResolutionResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnthropicIntentResolverBackendError.malformedResponse(
                detail: "top-level JSON is not an object"
            )
        }

        guard let stopReason = json["stop_reason"] as? String, stopReason == "tool_use" else {
            let reason = json["stop_reason"] as? String ?? "unknown"
            return makeUnresolved(intent, reason: .unsupportedVerb,
                                  message: "Model stopped with '\(reason)' instead of tool_use.")
        }

        guard let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { $0["type"] as? String == "tool_use" }),
              let rawToolName = toolUse["name"] as? String,
              let toolInput = toolUse["input"] as? [String: Any] else {
            throw AnthropicIntentResolverBackendError.malformedResponse(
                detail: "missing tool_use block in content"
            )
        }

        let verbID = decodedVerbID(rawToolName)
        guard let capability = capabilities.first(where: { $0.verbID == verbID }) else {
            return makeUnresolved(intent, reason: .unsupportedVerb,
                                  message: "Model chose unknown verb '\(verbID)'.")
        }

        let targetObjectIDs = (toolInput["target_object_ids"] as? [String]) ?? []
        var arguments: [String: IntentArgumentValue] = [:]
        for arg in capability.arguments {
            if let raw = toolInput[arg.name], let value = decodeArgument(raw, typeID: arg.typeID) {
                arguments[arg.name] = value
            }
        }

        let ir = IntentIR(
            verb: verbID,
            summary: capability.summary,
            targetObjectIDs: targetObjectIDs,
            arguments: arguments,
            confidence: 0.92,
            evidence: [IntentEvidence(kind: "ai_tool_use", summary: intent.text)],
            source: .ai
        )
        return IntentResolutionResult(naturalLanguageIntent: intent, intent: ir)
    }

    private func decodeArgument(_ raw: Any, typeID: String) -> IntentArgumentValue? {
        switch typeID {
        case "bool":
            if let v = raw as? Bool { return .bool(v) }
        case "i32":
            if let v = raw as? Int { return .integer(Int64(v)) }
            if let v = raw as? Int64 { return .integer(v) }
        case "f32":
            if let v = raw as? Double { return .number(v) }
            if let v = raw as? Int { return .number(Double(v)) }
        case "string", "doc_uri":
            if let v = raw as? String { return .string(v) }
        case "stable_id":
            if let v = raw as? String, let id = UInt64(v) { return .stableID(id) }
            if let v = raw as? Int, v >= 0 { return .stableID(UInt64(v)) }
        case "vec3":
            if let obj = raw as? [String: Any] {
                let x = (obj["x"] as? Double) ?? Double(obj["x"] as? Int ?? 0)
                let y = (obj["y"] as? Double) ?? Double(obj["y"] as? Int ?? 0)
                let z = (obj["z"] as? Double) ?? Double(obj["z"] as? Int ?? 0)
                return .vec3(IntentVector3(x: Float(x), y: Float(y), z: Float(z)))
            }
        default:
            if let v = raw as? String { return .string(v) }
        }
        return nil
    }

    // MARK: - Naming helpers

    /// Tool names must match `^[a-zA-Z0-9_-]{1,64}$` — replace dots with `__`.
    private func encodedToolName(_ verbID: String) -> String {
        verbID.replacingOccurrences(of: ".", with: "__")
    }

    private func decodedVerbID(_ toolName: String) -> String {
        toolName.replacingOccurrences(of: "__", with: ".")
    }

    // MARK: - Unresolved factory

    private func makeUnresolved(_ intent: NaturalLanguageIntent,
                                 reason: UnresolvableIntentReason,
                                 message: String) -> IntentResolutionResult {
        let unresolved = UnresolvableIntent(naturalLanguageIntent: intent,
                                            reason: reason,
                                            message: message)
        return IntentResolutionResult(naturalLanguageIntent: intent, unresolved: unresolved)
    }
}
