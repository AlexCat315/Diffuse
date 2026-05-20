import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IntentRuntime

public enum SessionError: Error, CustomStringConvertible, LocalizedError, Sendable {
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

    public var errorDescription: String? { description }
}

/// Per-project persistent AI participant.
///
/// Session maintains WorldView (incremental scene understanding) and
/// ConversationHistory (multi-turn context). It receives Signals, runs inference,
/// and produces Proposals. Inference is built-in — Session is the AI, not a
/// dispatcher to an external backend.
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
    /// Use `observe()` for state-update signals.
    /// `onProgress` is called with partial summary text as it streams in — use it to animate the UI.
    public func process(_ signal: Signal,
                        onProgress: (@Sendable (String) -> Void)? = nil) async throws -> Proposal {
        guard case let .naturalLanguage(text, _) = signal else {
            throw SessionError.unsupportedSignal(signal.kind)
        }
        recordTurn(ConversationTurn(kind: .userText(text)))
        let (plan, toolUseID, inputJSON) = try await infer(onProgress: onProgress)
        recordTurn(ConversationTurn(kind: .assistantToolCall(toolUseID: toolUseID,
                                                             name: "execute_edit_plan",
                                                             inputJSON: inputJSON)))
        return Proposal(
            sessionID: id,
            semanticIntent: text,
            plan: plan,
            baseSceneRevision: worldView.sceneRevision,
            reasoning: plan.reasoning,
            confidence: 0.85,
            approvalPolicy: .requiresApproval,
            toolUseID: toolUseID
        )
    }

    // MARK: - Outcome recording

    /// Records the outcome of a tool call as a tool_result message.
    /// Call after a Proposal is applied, discarded, or acknowledged.
    public func recordOutcome(toolUseID: String, content: String, proposalID: String? = nil) {
        recordTurn(ConversationTurn(kind: .toolResult(toolUseID: toolUseID, content: content),
                                    proposalID: proposalID))
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

    private func infer(onProgress: (@Sendable (String) -> Void)? = nil) async throws -> (SceneEditPlan, toolUseID: String, inputJSON: String) {
#if canImport(ObjectiveC)
        if let onProgress {
            return try await inferStreaming(onProgress: onProgress)
        }
#endif
        let body = requestBody()
        let data = try await post(body)
        return try parseResponse(from: data)
    }

#if canImport(ObjectiveC)
    private func inferStreaming(onProgress: @escaping @Sendable (String) -> Void) async throws -> (SceneEditPlan, toolUseID: String, inputJSON: String) {
        var body = requestBody()
        body["stream"] = true

        var request = URLRequest(url: inferenceEndpoint, timeoutInterval: config.timeoutInterval)
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

        let (stream, response) = try await urlSession.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var errData = Data()
            for try await byte in stream { errData.append(byte) }
            throw SessionError.httpError(statusCode: http.statusCode,
                                         body: String(data: errData, encoding: .utf8))
        }

        var toolUseID = ""
        var inputJSONAccumulator = ""
        var lastReportedSummary = ""

        for try await line in stream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            guard payload != "[DONE]" else { break }
            guard let eventData = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any]
            else { continue }

            switch config.apiFormat {
            case .anthropic:
                let type = event["type"] as? String ?? ""
                if type == "content_block_start",
                   let block = event["content_block"] as? [String: Any],
                   block["type"] as? String == "tool_use",
                   let id = block["id"] as? String {
                    toolUseID = id
                } else if type == "content_block_delta",
                          let delta = event["delta"] as? [String: Any],
                          delta["type"] as? String == "input_json_delta",
                          let fragment = delta["partial_json"] as? String {
                    inputJSONAccumulator += fragment
                    if let partial = extractPartialSummary(from: inputJSONAccumulator),
                       partial != lastReportedSummary {
                        lastReportedSummary = partial
                        onProgress(partial)
                    }
                }

            case .openAICompatible:
                if let choices = event["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let toolCalls = delta["tool_calls"] as? [[String: Any]],
                   let call = toolCalls.first {
                    if let id = call["id"] as? String, !id.isEmpty {
                        toolUseID = id
                    }
                    if let function = call["function"] as? [String: Any],
                       let fragment = function["arguments"] as? String {
                        inputJSONAccumulator += fragment
                        if let partial = extractPartialSummary(from: inputJSONAccumulator),
                           partial != lastReportedSummary {
                            lastReportedSummary = partial
                            onProgress(partial)
                        }
                    }
                }
            }
        }

        guard !toolUseID.isEmpty else { throw SessionError.noPlanInResponse }
        guard let planData = inputJSONAccumulator.data(using: .utf8) else {
            throw SessionError.planDecodingFailed(detail: "could not encode accumulated input as UTF-8")
        }
        do {
            let plan = try JSONDecoder().decode(SceneEditPlan.self, from: planData)
            return (plan, toolUseID, inputJSONAccumulator)
        } catch {
            throw SessionError.planDecodingFailed(detail: String(describing: error))
        }
    }
#endif

    private func extractPartialSummary(from json: String) -> String? {
        guard let keyRange = json.range(of: "\"summary\":\"") else { return nil }
        let after = json[keyRange.upperBound...]
        var result = ""
        var skipNext = false
        for ch in after {
            if skipNext { result.append(ch); skipNext = false; continue }
            if ch == "\\" { skipNext = true; continue }
            if ch == "\"" { break }
            result.append(ch)
        }
        return result.isEmpty ? nil : result
    }

    private func requestBody() -> [String: Any] {
        switch config.apiFormat {
        case .anthropic:
            return [
                "model": config.model,
                "max_tokens": config.maxTokens,
                "system": systemPrompt(),
                "tools": [EditPlanTool.definition()],
                "tool_choice": ["type": "any"],
                "messages": buildMessages(),
            ]
        case .openAICompatible:
            var messages: [[String: Any]] = [["role": "system", "content": systemPrompt()]]
            messages += buildMessages()
            return [
                "model": config.model,
                "max_tokens": config.maxTokens,
                "tools": [EditPlanTool.openAIDefinition()],
                "tool_choice": ["type": "function",
                                "function": ["name": "execute_edit_plan"]],
                "messages": messages,
            ]
        }
    }

    private func buildMessages() -> [[String: Any]] {
        var messages: [[String: Any]] = []
        for turn in conversationHistory {
            switch turn.kind {
            case let .userText(text):
                messages.append(["role": "user", "content": text])

            case let .assistantToolCall(toolUseID, name, inputJSON):
                switch config.apiFormat {
                case .anthropic:
                    let inputObject = (try? JSONSerialization.jsonObject(
                        with: Data(inputJSON.utf8))) ?? [String: Any]()
                    messages.append(["role": "assistant", "content": [
                        ["type": "tool_use", "id": toolUseID, "name": name, "input": inputObject]
                    ]])
                case .openAICompatible:
                    messages.append([
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": [["id": toolUseID,
                                        "type": "function",
                                        "function": ["name": name, "arguments": inputJSON]]],
                    ])
                }

            case let .toolResult(toolUseID, content):
                switch config.apiFormat {
                case .anthropic:
                    messages.append(["role": "user", "content": [
                        ["type": "tool_result", "tool_use_id": toolUseID, "content": content]
                    ]])
                case .openAICompatible:
                    messages.append(["role": "tool", "tool_call_id": toolUseID, "content": content])
                }
            }
        }
        return messages
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
        - For set_transform, use the `position` field (local space) as the base and only change \
        what the user asked for. When an entity is in a hierarchy, `evaluated.worldPosition` \
        shows its actual world-space position — use it for spatial reasoning but set_transform \
        always writes local space.
        - For snap_to_ground, set Y position to 0.
        - If the previous tool_result shows the user rejected your plan, adjust your approach.
        - If the user asks a general question (capabilities, greetings, clarifications) rather \
        than requesting a scene change, call the tool with an empty steps array and put your \
        conversational reply in the summary field.
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

    private func parseResponse(from data: Data) throws -> (SceneEditPlan, toolUseID: String, inputJSON: String) {
        switch config.apiFormat {
        case .anthropic:
            return try parseAnthropicResponse(from: data)
        case .openAICompatible:
            return try parseOpenAIResponse(from: data)
        }
    }

    private func parseAnthropicResponse(from data: Data) throws -> (SceneEditPlan, toolUseID: String, inputJSON: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionError.malformedResponse(detail: "top-level JSON is not an object")
        }
        guard let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { $0["type"] as? String == "tool_use" }),
              let toolUseID = toolUse["id"] as? String,
              let toolInput = toolUse["input"] as? [String: Any]
        else {
            throw SessionError.noPlanInResponse
        }
        guard let planData = try? JSONSerialization.data(withJSONObject: toolInput),
              let inputJSON = String(data: planData, encoding: .utf8)
        else {
            throw SessionError.planDecodingFailed(detail: "could not re-serialize tool input")
        }
        do {
            let plan = try JSONDecoder().decode(SceneEditPlan.self, from: planData)
            return (plan, toolUseID, inputJSON)
        } catch {
            throw SessionError.planDecodingFailed(detail: String(describing: error))
        }
    }

    private func parseOpenAIResponse(from data: Data) throws -> (SceneEditPlan, toolUseID: String, inputJSON: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let toolCalls = message["tool_calls"] as? [[String: Any]],
              let firstCall = toolCalls.first(where: { $0["type"] as? String == "function" }),
              let toolUseID = firstCall["id"] as? String,
              let function = firstCall["function"] as? [String: Any],
              let argumentsString = function["arguments"] as? String
        else {
            throw SessionError.noPlanInResponse
        }
        guard let planData = argumentsString.data(using: .utf8) else {
            throw SessionError.planDecodingFailed(detail: "could not encode arguments as UTF-8")
        }
        do {
            let plan = try JSONDecoder().decode(SceneEditPlan.self, from: planData)
            return (plan, toolUseID, argumentsString)
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
