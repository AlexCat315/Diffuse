import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ContextMemory
import IntentRuntime
import ObservationBus
import PerceptionRuntime

private extension WorldPropertyValue {
    /// JSON-serialisable form used only in the system prompt — human-readable, not tagged.
    var jsonValue: Any {
        switch self {
        case let .vec3(x, y, z):       return [x, y, z]
        case let .vec4(x, y, z, w):    return [x, y, z, w]
        case let .float(v):             return v
        case let .string(s):            return s
        case let .bool(b):              return b
        }
    }

    /// Compact string representation for ContextMemory payloads.
    var promptString: String {
        switch self {
        case let .vec3(x, y, z):        return "[\(x),\(y),\(z)]"
        case let .vec4(x, y, z, w):     return "[\(x),\(y),\(z),\(w)]"
        case let .float(v):             return String(v)
        case let .string(s):            return s
        case let .bool(b):              return b ? "true" : "false"
        }
    }
}


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
    public private(set) var workflowContext: WorkflowContext?
    private var observationBus: ObservationBus?
    private var contextMemory: ContextMemoryStore?
    private var cachedMemoryView: [[String: String]] = []
    private var perceptionService: PerceptionService?
    /// BCP-47 locale of the most recent naturalLanguage signal (e.g. "zh-Hans", "ja", "fr").
    /// Used to instruct the model to match the user's language in summaries and entity names.
    private var currentLocale: String? = nil

    private static let anthropicAPIVersion = "2023-06-01"
    private static let maxEntityPromptCount = 100

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
                workflowContext: WorkflowContext? = nil,
                urlSession: URLSession = .shared,
                maxHistoryTurns: Int = 40,
                initialWorldView: WorldView = WorldView()) {
        self.id = id
        self.config = config
        self.workflowContext = workflowContext
        self.urlSession = urlSession
        self.worldView = initialWorldView
        self.conversationHistory = []
        self.maxHistoryTurns = maxHistoryTurns
    }

    public func setWorkflowContext(_ context: WorkflowContext?) {
        workflowContext = context
        let mem = contextMemory
        guard let mem else { return }
        if let ctx = context {
            let entry = ContextEntry(
                id: "workflow:active",
                kind: .workflowContext,
                subject: "session",
                payload: Self.workflowPayload(from: ctx),
                importance: 0.5,
                revision: worldView.sceneRevision ?? 0
            )
            Task { await mem.upsert(entry) }
        } else {
            Task { await mem.remove(id: "workflow:active") }
        }
    }

    private static func workflowPayload(from ctx: WorkflowContext) -> [String: String] {
        switch ctx {
        case let .game(g):
            var p: [String: String] = [
                "kind": "game",
                "level_phase": g.levelPhase.rawValue,
                "genre": g.gameplayIntent.genre,
                "win_condition": g.gameplayIntent.winCondition,
                "target_experience": g.targetExperience,
            ]
            if !g.knownConstraints.scriptingRegistry.isEmpty {
                p["scripting_registry"] = g.knownConstraints.scriptingRegistry.joined(separator: ",")
            }
            return p
        case let .film(f):
            var p: [String: String] = [
                "kind": "film",
                "narrative_phase": f.narrativePhase.rawValue,
                "active_sequence": f.activeSequenceID,
            ]
            if let shot = f.activeShotID { p["active_shot"] = shot }
            if let intent = f.directorIntent, !intent.isEmpty { p["director_intent"] = String(intent.prefix(256)) }
            if !f.lockedShotIDs.isEmpty { p["locked_shots"] = f.lockedShotIDs.joined(separator: ",") }
            return p
        }
    }

    public func setObservationBus(_ bus: ObservationBus?) {
        observationBus = bus
    }

    public func setContextMemory(_ store: ContextMemoryStore?) {
        contextMemory = store
    }

    public func setPerceptionService(_ service: PerceptionService?) {
        perceptionService = service
    }

    // MARK: - Perception

    /// Runs perception on `imageURL`, applies the resulting inferred WorldEvents to the
    /// WorldView, and (if a ContextMemoryStore is configured) records a `sceneAnnotation`
    /// entry for each observation.
    ///
    /// - Parameters:
    ///   - ref: Entity reference, e.g. `"scene:42"`.
    ///   - imageURL: Local file URL of the image to analyse.
    ///   - task: Which perception task to run. Defaults to `.classification`.
    ///   - maxResults: Maximum number of observations. Defaults to 5.
    /// - Returns: The WorldEvents that were applied (useful for callers that also drive the bus).
    @discardableResult
    public func tagEntity(ref: String,
                          imageURL: URL,
                          task: PerceptionTask = .classification,
                          maxResults: Int = 5) async throws -> [WorldEvent] {
        guard let svc = perceptionService else {
            throw PerceptionRuntimeError.workerUnavailable("no PerceptionService configured on this Session")
        }
        let events = try await svc.tag(entityRef: ref,
                                       imageURL: imageURL,
                                       task: task,
                                       maxResults: maxResults)
        for event in events { worldView.apply(event: event) }
        if let mem = contextMemory {
            for event in events {
                if case let .entityInferredUpdated(entityRef, property, value, confidence, source) = event {
                    let entryID = "percept:\(entityRef):\(property)"
                    let entry = ContextEntry(
                        id: entryID,
                        kind: .sceneAnnotation,
                        subject: entityRef,
                        payload: [
                            "property": property,
                            "value": value.promptString,
                            "confidence": String(format: "%.3f", confidence),
                            "source": source ?? "perception",
                        ],
                        importance: min(0.9, max(0.3, confidence)),
                        revision: worldView.sceneRevision ?? 0
                    )
                    Task { await mem.upsert(entry) }
                }
            }
        }
        return events
    }

    // MARK: - Signal processing

    /// Runs inference on a NaturalLanguage or UserCorrection signal and returns a Proposal.
    /// Use `observe()` for state-update signals (selectionChanged, worldChanged).
    /// `onProgress` is called with partial summary text as it streams in — use it to animate the UI.
    public func process(_ signal: Signal,
                        onProgress: (@Sendable (String) -> Void)? = nil) async throws -> Proposal {
        switch signal {
        case let .naturalLanguage(text, locale):
            if !locale.isEmpty { currentLocale = locale }
            recordTurn(ConversationTurn(kind: .userText(text)))
            let (plan, toolUseID, inputJSON) = try await infer(onProgress: onProgress)
            recordTurn(ConversationTurn(kind: .assistantToolCall(toolUseID: toolUseID,
                                                                 name: "execute_edit_plan",
                                                                 inputJSON: inputJSON)))
            updateIssueMemory(intent: text, plan: plan)
            return Proposal(
                sessionID: id,
                semanticIntent: text,
                plan: plan,
                baseSceneRevision: worldView.sceneRevision,
                reasoning: plan.reasoning,
                confidence: planConfidence(for: plan),
                approvalPolicy: config.autoApprove ? .automatic : .requiresApproval,
                toolUseID: toolUseID
            )

        case let .userCorrection(proposalID, acceptedStepIDs, rejectedStepIDs):
            return try await processCorrection(proposalID: proposalID,
                                               acceptedStepIDs: acceptedStepIDs,
                                               rejectedStepIDs: rejectedStepIDs,
                                               onProgress: onProgress)

        case let .referenceImage(url, entityRef):
            return try await processReferenceImage(url: url, entityRef: entityRef,
                                                   onProgress: onProgress)

        default:
            throw SessionError.unsupportedSignal(signal.kind)
        }
    }

    /// Handles a userCorrection signal: records the partial outcome as a tool_result,
    /// then re-infers only when there are rejected steps that need revision.
    private func processCorrection(proposalID: String,
                                   acceptedStepIDs: [String],
                                   rejectedStepIDs: [String],
                                   onProgress: (@Sendable (String) -> Void)?) async throws -> Proposal {
        // Find the most recent assistant tool call so we can close the conversation turn.
        guard let callTurn = conversationHistory.last(where: {
                  if case .assistantToolCall = $0.kind { return true }; return false }),
              case let .assistantToolCall(toolUseID, _, _) = callTurn.kind
        else { throw SessionError.unsupportedSignal("userCorrection: no prior plan in history") }

        // Record the outcome so the model sees what happened.
        let outcomeContent: String
        if rejectedStepIDs.isEmpty {
            outcomeContent = "All steps applied successfully."
        } else if acceptedStepIDs.isEmpty {
            outcomeContent = "Plan rejected entirely. Please propose a different approach."
        } else {
            let accepted = acceptedStepIDs.joined(separator: ", ")
            let rejected = rejectedStepIDs.joined(separator: ", ")
            outcomeContent = "Partial application. Accepted: [\(accepted)]. Rejected: [\(rejected)]. Revise the rejected steps."
        }
        recordTurn(ConversationTurn(kind: .toolResult(toolUseID: toolUseID, content: outcomeContent),
                                    proposalID: proposalID))

        // Nothing was rejected — no revision needed.
        if rejectedStepIDs.isEmpty {
            return Proposal(sessionID: id,
                            semanticIntent: "",
                            plan: SceneEditPlan(summary: "All steps accepted.", steps: []),
                            baseSceneRevision: worldView.sceneRevision,
                            confidence: 1.0,
                            approvalPolicy: .automatic,
                            toolUseID: toolUseID)
        }

        // Record rejected steps as a userPreference entry so future sessions avoid the pattern.
        if let mem = contextMemory, !rejectedStepIDs.isEmpty {
            let rejectedList = rejectedStepIDs.joined(separator: ",")
            let entry = ContextEntry(
                id: "pref:rejected:\(proposalID)",
                kind: .userPreference,
                subject: "session",
                payload: ["rejected_steps": rejectedList,
                          "proposal_id": proposalID],
                importance: 0.7
            )
            Task { await mem.upsert(entry) }
        }

        // Re-infer a revised plan for the rejected steps.
        let (plan, newToolUseID, inputJSON) = try await infer(onProgress: onProgress)
        recordTurn(ConversationTurn(kind: .assistantToolCall(toolUseID: newToolUseID,
                                                             name: "execute_edit_plan",
                                                             inputJSON: inputJSON)))
        return Proposal(
            sessionID: id,
            semanticIntent: "Correction: \(rejectedStepIDs.count) step(s) to revise",
            plan: plan,
            baseSceneRevision: worldView.sceneRevision,
            reasoning: plan.reasoning,
            confidence: planConfidence(for: plan),
            approvalPolicy: config.autoApprove ? .automatic : .requiresApproval,
            toolUseID: newToolUseID
        )
    }

    private func processReferenceImage(url: URL,
                                        entityRef: String?,
                                        onProgress: (@Sendable (String) -> Void)?) async throws -> Proposal {
        let userMessage: String
        if let ref = entityRef {
            let filename = url.lastPathComponent
            userMessage = """
            I have attached a reference image ("\(filename)") for entity \(ref). \
            Perception has already run and inferred properties are visible in the scene entity list. \
            Based on those inferred observations and the surrounding scene, produce a scene edit plan \
            that names, organizes, or extends the entity appropriately. \
            If the inferred properties do not suggest any useful edits, reply with an empty steps array \
            and explain in the summary.
            """
        } else {
            let filename = url.lastPathComponent
            userMessage = """
            I have provided a reference image ("\(filename)") for scene creation. \
            Perception has run and any inferred entity properties appear in the scene entity list. \
            Based on those observations and the current scene context, produce a scene edit plan \
            that populates or refines the scene to match the reference. \
            If no actionable changes can be derived, reply with an empty steps array.
            """
        }
        recordTurn(ConversationTurn(kind: .userText(userMessage)))
        let (plan, toolUseID, inputJSON) = try await infer(onProgress: onProgress)
        recordTurn(ConversationTurn(kind: .assistantToolCall(toolUseID: toolUseID,
                                                             name: "execute_edit_plan",
                                                             inputJSON: inputJSON)))
        return Proposal(
            sessionID: id,
            semanticIntent: userMessage,
            plan: plan,
            baseSceneRevision: worldView.sceneRevision,
            reasoning: plan.reasoning,
            confidence: planConfidence(for: plan),
            approvalPolicy: config.autoApprove ? .automatic : .requiresApproval,
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
        let mem = contextMemory
        if let mem { Task { await mem.apply(event: event) } }
    }

    /// Applies a batch of WorldEvents in order.
    public func observe(events: [WorldEvent]) {
        for event in events { worldView.apply(event: event) }
        let mem = contextMemory
        if let mem { Task { await mem.apply(events: events) } }
    }

    public func replaceWorldView(_ worldView: WorldView) {
        self.worldView = worldView
    }

    public func worldViewSnapshot() -> WorldView {
        worldView
    }

    public func observe(editSummary: String, revision: UInt64) {
        worldView.apply(editSummary: editSummary, revision: revision)
        let mem = contextMemory
        if let mem { Task { try? await mem.flush() } }
    }

    /// Persists the context memory store to disk (if a storageURL was configured).
    public func flushContextMemory() async throws {
        try await contextMemory?.flush()
    }

    // MARK: - Issue memory

    /// Records or clears an `issueTracked` entry based on whether the plan is empty.
    ///
    /// An empty plan means the model couldn't fulfill the intent — we record the
    /// outstanding request so future sessions know it's unresolved. When a subsequent
    /// request for the same intent produces a non-empty plan, we remove the stale entry.
    func updateIssueMemory(intent: String, plan: SceneEditPlan) {
        guard let mem = contextMemory else { return }
        let key = Self.issueKey(for: intent)
        if plan.isEmpty {
            let reason = plan.summary.isEmpty ? "no steps produced" : plan.summary
            let entry = ContextEntry(
                id: key,
                kind: .issueTracked,
                subject: "session",
                payload: ["intent": String(intent.prefix(256)), "reason": reason],
                importance: 0.6,
                revision: worldView.sceneRevision ?? 0
            )
            Task { await mem.upsert(entry) }
        } else {
            Task { await mem.remove(id: key) }
        }
    }

    static func issueKey(for intent: String) -> String {
        let normalized = intent.prefix(48).lowercased()
            .unicodeScalars
            .filter { $0.value < 128 }
            .map { Character($0) }
            .map { ($0.isLetter || $0.isNumber) ? $0 : Character("_") }
        return "issue:" + String(normalized)
    }

    public func observe(selectionChanged entityRefs: [String]) {
        worldView.apply(selectionChanged: entityRefs)
    }

    public func entityRecord(ref: String) -> WorldEntityRecord? {
        worldView.entityIndex[ref]
    }

    // MARK: - History

    public func clearHistory() {
        recordSessionSummary()
        conversationHistory.removeAll()
    }

    private func recordSessionSummary() {
        guard let mem = contextMemory, !conversationHistory.isEmpty else { return }
        let intents: [String] = conversationHistory.compactMap {
            guard case let .userText(text) = $0.kind else { return nil }
            return String(text.prefix(120))
        }
        guard !intents.isEmpty else { return }
        let turnCount = conversationHistory.count
        let revision = worldView.sceneRevision ?? 0
        let entry = ContextEntry(
            id: "summary:\(id)",
            kind: .sessionSummary,
            subject: "session",
            payload: [
                "turn_count": String(turnCount),
                "intent_count": String(intents.count),
                "last_intents": intents.suffix(5).joined(separator: " | "),
                "scene_revision": String(revision),
            ],
            importance: 0.5,
            revision: revision
        )
        Task { await mem.upsert(entry) }
    }

    public func historySnapshot() -> [ConversationTurn] {
        conversationHistory
    }

    // MARK: - Inference

    private func infer(onProgress: (@Sendable (String) -> Void)? = nil) async throws -> (SceneEditPlan, toolUseID: String, inputJSON: String) {
        if let mem = contextMemory {
            cachedMemoryView = await mem.symbolicView(budget: 20)
        }
#if canImport(ObjectiveC)
        if let onProgress {
            return try await inferStreamingLoop(onProgress: onProgress)
        }
#endif
        return try await inferNonStreamingLoop()
    }

    private func inferNonStreamingLoop() async throws -> (SceneEditPlan, toolUseID: String, inputJSON: String) {
        var extraMessages: [[String: Any]] = []
        var findCallsRemaining = 3
        while true {
            let body = requestBody(extraMessages: extraMessages)
            let data = try await post(body)
            let call = try parseRawToolCall(from: data)
            if call.name == "execute_edit_plan" {
                return try decodePlan(from: call)
            } else if call.name == "find_entities", findCallsRemaining > 0 {
                findCallsRemaining -= 1
                let resultJSON = findEntitiesResult(input: call.input)
                extraMessages += toolCallExchangeMessages(call: call, resultJSON: resultJSON)
            } else {
                throw SessionError.noPlanInResponse
            }
        }
    }

#if canImport(ObjectiveC)
    private func inferStreamingLoop(onProgress: @escaping @Sendable (String) -> Void) async throws -> (SceneEditPlan, toolUseID: String, inputJSON: String) {
        var extraMessages: [[String: Any]] = []
        var findCallsRemaining = 3
        while true {
            let call = try await streamOneTurn(extraMessages: extraMessages, onProgress: onProgress)
            if call.name == "execute_edit_plan" {
                return try decodePlan(from: call)
            } else if call.name == "find_entities", findCallsRemaining > 0 {
                findCallsRemaining -= 1
                let resultJSON = findEntitiesResult(input: call.input)
                extraMessages += toolCallExchangeMessages(call: call, resultJSON: resultJSON)
            } else {
                throw SessionError.noPlanInResponse
            }
        }
    }

    private func streamOneTurn(extraMessages: [[String: Any]],
                               onProgress: @escaping @Sendable (String) -> Void) async throws -> RawToolCall {
        var body = requestBody(extraMessages: extraMessages)
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
        var toolName = ""
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
                    toolName = block["name"] as? String ?? ""
                } else if type == "content_block_delta",
                          let delta = event["delta"] as? [String: Any],
                          delta["type"] as? String == "input_json_delta",
                          let fragment = delta["partial_json"] as? String {
                    inputJSONAccumulator += fragment
                    if toolName == "execute_edit_plan",
                       let partial = extractPartialSummary(from: inputJSONAccumulator),
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
                    if let function = call["function"] as? [String: Any] {
                        if let name = function["name"] as? String, !name.isEmpty {
                            toolName = name
                        }
                        if let fragment = function["arguments"] as? String {
                            inputJSONAccumulator += fragment
                            if toolName == "execute_edit_plan",
                               let partial = extractPartialSummary(from: inputJSONAccumulator),
                               partial != lastReportedSummary {
                                lastReportedSummary = partial
                                onProgress(partial)
                            }
                        }
                    }
                }
            }
        }

        guard !toolUseID.isEmpty else { throw SessionError.noPlanInResponse }
        guard let inputData = inputJSONAccumulator.data(using: .utf8),
              let inputObject = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any]
        else {
            return RawToolCall(name: toolName, id: toolUseID, inputJSON: inputJSONAccumulator, input: [:])
        }
        return RawToolCall(name: toolName, id: toolUseID, inputJSON: inputJSONAccumulator, input: inputObject)
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

    private func requestBody(extraMessages: [[String: Any]] = []) -> [String: Any] {
        let allMessages = buildMessages() + extraMessages
        switch config.apiFormat {
        case .anthropic:
            return [
                "model": config.model,
                "max_tokens": config.maxTokens,
                "system": systemPrompt(),
                "tools": [EditPlanTool.definition(), FindEntitiesTool.definition()],
                "tool_choice": ["type": "any"],
                "messages": allMessages,
            ]
        case .openAICompatible:
            var messages: [[String: Any]] = [["role": "system", "content": systemPrompt()]]
            messages += allMessages
            return [
                "model": config.model,
                "max_tokens": config.maxTokens,
                "tools": [EditPlanTool.openAIDefinition(), FindEntitiesTool.openAIDefinition()],
                "tool_choice": "required",
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

        var entitySection = "Scene entities (JSON):\n\(entityIndexJSON())"
        if let note = entityTruncationNote() { entitySection += "\n\n" + note }
        parts.append(entitySection)

        if !worldView.recentEdits.isEmpty {
            let lines = worldView.recentEdits.suffix(10)
                .map { "- \($0.summary) (rev \($0.revision))" }
                .joined(separator: "\n")
            parts.append("Recent edits (most recent last):\n\(lines)")
        }

        if !cachedMemoryView.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: cachedMemoryView,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            parts.append("Long-term context memory (most important first):\n\(str)")
        }

        if let bus = observationBus {
            let txView = bus.symbolicView(streamID: "transaction", fromSeq: 0, maxCount: 10)
            if !txView.events.isEmpty {
                parts.append(txView.promptText())
            }
        }

        if let ctx = workflowContext {
            parts.append(ctx.systemPromptSection)
        } else if let mode = worldView.workflowMode {
            parts.append("Active workflow mode: \(mode)")
        }

        if !worldView.selectedEntityRefs.isEmpty {
            parts.append("Currently selected: \(worldView.selectedEntityRefs.joined(separator: ", "))")
        }

        if let locale = currentLocale, !locale.hasPrefix("en") {
            parts.append("User locale: \(locale) — write entity names, labels, and the plan summary in the user's language where appropriate.")
        }

        parts.append("""
        Rules:
        - Only operate on entities that exist in the scene entities list above.
        - Use the exact entity IDs from the list (format: "scene:<number>").
        - Prefer minimal plans — only include steps necessary to satisfy the request.
        - When "Currently selected" is non-empty, treat those entities as the user's primary \
        target for any ambiguous request (e.g. "make it bigger", "delete it", "change the colour"). \
        Only operate on non-selected entities when the request clearly names or describes them.
        - For reparent_entity: moving an entity to a new parent changes its local transform \
        relative to that parent. After reparenting, follow up with set_transform if the entity's \
        world position should be preserved.
        - For set_transform, use the `position`, `scale`, and `eulerDegrees` fields (all local \
        space) as the base and only change what the user asked for. When an entity is in a \
        hierarchy, `evaluated.worldPosition` shows its actual world-space position, \
        `evaluated.worldEulerDegrees` shows world-space rotation, and `evaluated.worldScale` \
        shows the cumulative world-space scale — use these for spatial reasoning, but \
        set_transform always writes local space.
        - The `scale` field is omitted when uniform [1, 1, 1]; treat missing `scale` as [1, 1, 1].
        - The `eulerDegrees` field is omitted when the rotation is [0, 0, 0]; treat missing \
        `eulerDegrees` as [0, 0, 0]. Angles are XYZ intrinsic Euler in degrees.
        - For snap_to_ground, set Y position to 0.
        - For set_camera_fov: use `camera_fov_y` (degrees, 1–179). 30≈telephoto, 50≈normal, 75≈wide.
        - For set_camera_active: use `camera_is_active` (boolean). Only one camera should be active at a time.
        - Each entity may have an `inferred` dict with AI perception observations (e.g. object \
        category, semantic role). Use high-confidence (≥0.8) inferred properties to understand \
        what the entity represents in the real world when naming, grouping, or describing it.
        - If the previous tool_result shows the user rejected your plan, adjust your approach.
        - For set_script_property: use `script_property_name` (the parameter key) and \
        `script_property_value` (the new value — string, number, or boolean). The entity's \
        `scriptBindings` shows existing scripts and their current `params`. Use `script_index` \
        (default 0) to target a specific binding when an entity has multiple scripts.
        - For set_collider_layer: use `collider_layer_id` (0–15, which layer the collider \
        occupies) and/or `collider_layer_mask` (bitmask of layers this collider interacts with, \
        e.g. 0xFFFF = collide with all layers). An entity's `colliderLayerID` and \
        `colliderLayerMask` fields show the current values.
        - For set_material: use `material_base_color` ([r,g,b,a] linear 0–1), \
        `material_metallic` (0–1; 0=dielectric, 1=full metal), \
        `material_roughness` (0–1; 0=mirror-smooth, 1=fully rough), and \
        `material_emissive` ([r,g,b] linear 0–1; omit for no change). \
        Omitting any field preserves the entity's current value — only include fields you want \
        to change. An entity's `materialBaseColor`, `materialMetallic`, `materialRoughness`, and \
        `materialEmissive` fields show the current PBR values when non-default. \
        Prefer set_material over set_mesh_color for precise or multi-channel appearance control; \
        use set_mesh_color only for a simple RGB tint when no PBR properties are needed.
        - If the user asks a general question (capabilities, greetings, clarifications) rather \
        than requesting a scene change, call the tool with an empty steps array and put your \
        conversational reply in the summary field.
        - For set_audio_source: `audio_pitch` (1.0=normal, 2.0=one octave up, 0.5=one octave down) \
        and `audio_spatial_blend` (0=fully 2D, 1=fully 3D positional) are shown in `audioPitch` \
        and `audioSpatialBlend` only when non-default (pitch≠1.0 or blend>0). Omitting any \
        field preserves the current value.
        - Use find_entities (name substring, kind, or component filter) to locate entities whose \
        IDs are not visible in the scene list. The `component` parameter accepts tags like "light", \
        "camera", "rigidbody", "collider", "audio_source", "animation", "script", "constraint". \
        After find_entities returns its result, call execute_edit_plan with the discovered IDs.
        """)

        return parts.joined(separator: "\n\n")
    }

    private func entityIndexJSON() -> String {
        guard !worldView.entityIndex.isEmpty else { return "[]" }
        let all = worldView.entityIndex
        let limit = Self.maxEntityPromptCount

        let prioritized: [WorldEntityRecord]
        if all.count <= limit {
            prioritized = all.values.sorted { $0.ref < $1.ref }
        } else {
            // Always include selected entities plus their immediate parents and children.
            var priorityRefs = Set(worldView.selectedEntityRefs)
            for ref in worldView.selectedEntityRefs {
                if let record = all[ref] {
                    if let parent = record.parentRef { priorityRefs.insert(parent) }
                    priorityRefs.formUnion(record.childRefs)
                }
            }
            var result = priorityRefs.compactMap { all[$0] }
            let remainingSlots = limit - result.count
            if remainingSlots > 0 {
                let others = all.values
                    .filter { !priorityRefs.contains($0.ref) }
                    .sorted { $0.ref < $1.ref }
                    .prefix(remainingSlots)
                result.append(contentsOf: others)
            }
            prioritized = result.sorted { $0.ref < $1.ref }
        }

        let dicts = prioritized.map(compactDict(for:))
        guard let data = try? JSONSerialization.data(withJSONObject: dicts,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }

    /// Returns a note string when entity count exceeds the prompt limit; nil otherwise.
    private func entityTruncationNote() -> String? {
        let total = worldView.entityIndex.count
        guard total > Self.maxEntityPromptCount else { return nil }
        return "Note: scene has \(total) entities; only \(Self.maxEntityPromptCount) are shown above " +
               "(selected entities and their neighbours are prioritised). " +
               "Use the find_entities tool to search for entities by name or kind before calling execute_edit_plan."
    }

    nonisolated func compactDict(for e: WorldEntityRecord) -> [String: Any] {
        var d: [String: Any] = ["ref": e.ref, "name": e.name]
        if let v = e.kind               { d["kind"] = v }
        if !e.components.isEmpty        { d["components"] = e.components }
        if let v = e.parentRef          { d["parentRef"] = v }
        if !e.childRefs.isEmpty         { d["childRefs"] = e.childRefs }
        if let v = e.position           { d["position"] = v }
        if let v = e.scale              { d["scale"] = v }
        if let v = e.eulerDegrees       { d["eulerDegrees"] = v }
        if let v = e.lightType          { d["lightType"] = v }
        if let v = e.lightIntensity     { d["lightIntensity"] = v }
        if let v = e.lightColor         { d["lightColor"] = v }
        if let v = e.lightRange         { d["lightRange"] = v }
        if let v = e.lightSpotInner     { d["lightSpotInner"] = v }
        if let v = e.lightSpotOuter     { d["lightSpotOuter"] = v }
        if let v = e.lightCastShadows   { d["lightCastShadows"] = v }
        if let v = e.cameraFovYDegrees  { d["cameraFovYDegrees"] = v }
        if let v = e.cameraIsActive     { d["cameraIsActive"] = v }
        if let v = e.meshColor          { d["meshColor"] = v }
        if let v = e.materialBaseColor  { d["materialBaseColor"] = v }
        if let v = e.materialMetallic   { d["materialMetallic"] = v }
        if let v = e.materialRoughness  { d["materialRoughness"] = v }
        if let v = e.materialEmissive   { d["materialEmissive"] = v }
        if let v = e.rigidBodyMotionType  { d["rigidBodyMotionType"] = v }
        if let v = e.rigidBodyMass        { d["rigidBodyMass"] = v }
        if let v = e.rigidBodyGravityScale { d["rigidBodyGravityScale"] = v }
        if let v = e.rigidBodyAllowSleep  { d["rigidBodyAllowSleep"] = v }
        if let v = e.colliderShape        { d["colliderShape"] = v }
        if let v = e.colliderIsTrigger    { d["colliderIsTrigger"] = v }
        if let v = e.colliderFriction     { d["colliderFriction"] = v }
        if let v = e.colliderRestitution  { d["colliderRestitution"] = v }
        if let v = e.colliderDensity      { d["colliderDensity"] = v }
        if let v = e.colliderLayerID     { d["colliderLayerID"] = v }
        if let v = e.colliderLayerMask   { d["colliderLayerMask"] = v }
        if let v = e.audioClip            { d["audioClip"] = v }
        if let v = e.audioVolume          { d["audioVolume"] = v }
        if let v = e.audioLoop            { d["audioLoop"] = v }
        if let v = e.audioPlayOnAwake     { d["audioPlayOnAwake"] = v }
        if let v = e.audioPitch           { d["audioPitch"] = v }
        if let v = e.audioSpatialBlend    { d["audioSpatialBlend"] = v }
        if let v = e.meshIsVisible, !v  { d["meshIsVisible"] = false }
        if let v = e.animationClip      { d["animationClip"] = v }
        if let v = e.animationSpeed     { d["animationSpeed"] = v }
        if let v = e.animationLoop      { d["animationLoop"] = v }
        if let v = e.animationIsPlaying { d["animationIsPlaying"] = v }
        if let v = e.constraintEnabled  { d["constraintEnabled"] = v }
        if let bindings = e.scriptBindings, !bindings.isEmpty {
            d["scriptBindings"] = bindings.map { b -> [String: Any] in
                var entry: [String: Any] = ["handle": b.handle, "enabled": b.isEnabled]
                if b.parametersJSON != "{}" && !b.parametersJSON.isEmpty,
                   let data = b.parametersJSON.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    entry["params"] = parsed
                }
                return entry
            }
        }
        if !e.evaluated.isEmpty {
            d["evaluated"] = e.evaluated.mapValues(\.jsonValue)
        }
        if !e.inferred.isEmpty {
            d["inferred"] = e.inferred.mapValues { inf -> [String: Any] in
                var entry: [String: Any] = ["value": inf.displayValue, "confidence": inf.confidence]
                if let src = inf.source { entry["source"] = src }
                return entry
            }
        }
        return d
    }

    // MARK: - Confidence

    private func planConfidence(for plan: SceneEditPlan) -> Double {
        Session.confidence(for: plan)
    }

    /// Derives a confidence score for a plan.
    ///
    /// Starts at 1.0 and applies penalties and bonuses:
    /// - Each step beyond the first reduces confidence slightly (large plans are riskier).
    /// - `deleteEntity` applies a large penalty — it is irreversible.
    /// - Steps that touch many distinct entities are penalised as broad-impact (>5 entities).
    /// - Spawn without a subsequent setTransform is penalised (orphan entity).
    /// - `deleteEntity` without any spawn in the same plan is penalised harder.
    /// - A non-empty `reasoning` field is a weak positive signal (+0.05 cap at 1.0).
    /// - Empty plans (conversational response) are always 1.0.
    static func confidence(for plan: SceneEditPlan) -> Double {
        guard !plan.steps.isEmpty else { return 1.0 }
        var score = 1.0
        var affectedEntityIDs = Set<String>()
        var hasSpawn = false
        var hasDelete = false

        for (i, step) in plan.steps.enumerated() {
            if i > 0 { score -= 0.03 }
            if step.op == .deleteEntity { score -= 0.10; hasDelete = true }
            if step.op == .spawnEntity  { hasSpawn = true }
            if let ref = step.entityRef { affectedEntityIDs.insert(ref) }
        }

        // Broad-impact penalty: more than 5 distinct entities touched.
        let broadPenalty = max(0, affectedEntityIDs.count - 5)
        score -= Double(broadPenalty) * 0.02

        // Orphan spawn penalty: spawnEntity with no subsequent setTransform.
        let hasTransformStep = plan.steps.contains { $0.op == .setTransform }
        if hasSpawn && !hasTransformStep { score -= 0.05 }

        // Uncompensated delete penalty: deleting without spawning a replacement is riskier.
        if hasDelete && !hasSpawn { score -= 0.05 }

        // Reasoning bonus: model explained its intent, suggesting higher-quality output.
        if let r = plan.reasoning, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score = min(1.0, score + 0.05)
        }

        return max(0.40, score)
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

    // MARK: - Agentic loop helpers

    /// Intermediate result of one API round-trip: tool name, ID, and raw input.
    private struct RawToolCall {
        var name: String
        var id: String
        var inputJSON: String
        var input: [String: Any]
    }

    /// Parses a raw tool call from a non-streaming API response (either format).
    private func parseRawToolCall(from data: Data) throws -> RawToolCall {
        switch config.apiFormat {
        case .anthropic:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SessionError.malformedResponse(detail: "top-level JSON is not an object")
            }
            guard let content = json["content"] as? [[String: Any]],
                  let toolUse = content.first(where: { $0["type"] as? String == "tool_use" }),
                  let id = toolUse["id"] as? String,
                  let name = toolUse["name"] as? String,
                  let input = toolUse["input"] as? [String: Any]
            else { throw SessionError.noPlanInResponse }
            let inputJSON: String
            if let d = try? JSONSerialization.data(withJSONObject: input),
               let s = String(data: d, encoding: .utf8) { inputJSON = s } else { inputJSON = "{}" }
            return RawToolCall(name: name, id: id, inputJSON: inputJSON, input: input)

        case .openAICompatible:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let toolCalls = message["tool_calls"] as? [[String: Any]],
                  let firstCall = toolCalls.first(where: { $0["type"] as? String == "function" }),
                  let id = firstCall["id"] as? String,
                  let function = firstCall["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  let argsString = function["arguments"] as? String
            else { throw SessionError.noPlanInResponse }
            let input = (try? JSONSerialization.jsonObject(with: Data(argsString.utf8))) as? [String: Any] ?? [:]
            return RawToolCall(name: name, id: id, inputJSON: argsString, input: input)
        }
    }

    /// Decodes a SceneEditPlan from a RawToolCall that should be `execute_edit_plan`.
    private func decodePlan(from call: RawToolCall) throws -> (SceneEditPlan, toolUseID: String, inputJSON: String) {
        guard let planData = call.inputJSON.data(using: .utf8) else {
            throw SessionError.planDecodingFailed(detail: "could not encode input as UTF-8")
        }
        do {
            let plan = try JSONDecoder().decode(SceneEditPlan.self, from: planData)
            return (plan, call.id, call.inputJSON)
        } catch {
            throw SessionError.planDecodingFailed(detail: String(describing: error))
        }
    }

    /// Searches worldView.entityIndex for the given name/kind query and returns a JSON result string.
    func findEntitiesResult(input: [String: Any]) -> String {
        let nameQuery = (input["name"] as? String)?.lowercased()
        let kindFilter = input["kind"] as? String
        let componentFilter = (input["component"] as? String)?.lowercased()
        let limit = max(1, min((input["limit"] as? Int) ?? 20, 200))
        var results: [[String: Any]] = []
        for e in worldView.entityIndex.values.sorted(by: { $0.ref < $1.ref }) {
            if let nq = nameQuery, !e.name.lowercased().contains(nq) { continue }
            if let kf = kindFilter, e.kind != kf { continue }
            if let cf = componentFilter,
               !e.components.contains(where: { $0.lowercased() == cf }) { continue }
            var entry: [String: Any] = ["id": e.ref, "name": e.name]
            if let k = e.kind { entry["kind"] = k }
            if !e.components.isEmpty { entry["components"] = e.components }
            results.append(entry)
            if results.count >= limit { break }
        }
        let response: [String: Any] = ["count": results.count, "entities": results]
        guard let data = try? JSONSerialization.data(withJSONObject: response),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    /// Builds the assistant tool-call message and tool-result message pair for appending to extraMessages.
    private func toolCallExchangeMessages(call: RawToolCall, resultJSON: String) -> [[String: Any]] {
        switch config.apiFormat {
        case .anthropic:
            let assistantMsg: [String: Any] = [
                "role": "assistant",
                "content": [
                    ["type": "tool_use", "id": call.id, "name": call.name,
                     "input": call.input],
                ],
            ]
            let resultMsg: [String: Any] = [
                "role": "user",
                "content": [
                    ["type": "tool_result", "tool_use_id": call.id, "content": resultJSON],
                ],
            ]
            return [assistantMsg, resultMsg]

        case .openAICompatible:
            let assistantMsg: [String: Any] = [
                "role": "assistant",
                "content": NSNull(),
                "tool_calls": [
                    ["id": call.id, "type": "function",
                     "function": ["name": call.name, "arguments": call.inputJSON]],
                ],
            ]
            let resultMsg: [String: Any] = [
                "role": "tool", "tool_call_id": call.id, "content": resultJSON,
            ]
            return [assistantMsg, resultMsg]
        }
    }

    // MARK: - History

    func recordTurn(_ turn: ConversationTurn) {
        conversationHistory.append(turn)
        // Remove complete interaction triples (userText + assistantToolCall + toolResult)
        // from the front so we never leave an orphaned tool call at the start of the message list.
        while conversationHistory.count > maxHistoryTurns {
            if conversationHistory.count >= 3,
               case .userText = conversationHistory[0].kind {
                conversationHistory.removeFirst(3)
            } else {
                conversationHistory.removeFirst()
            }
        }
    }
}
