import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IntentRuntime
import ObservationBus

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
    }

    public func setObservationBus(_ bus: ObservationBus?) {
        observationBus = bus
    }

    // MARK: - Signal processing

    /// Runs inference on a NaturalLanguage or UserCorrection signal and returns a Proposal.
    /// Use `observe()` for state-update signals (selectionChanged, worldChanged).
    /// `onProgress` is called with partial summary text as it streams in — use it to animate the UI.
    public func process(_ signal: Signal,
                        onProgress: (@Sendable (String) -> Void)? = nil) async throws -> Proposal {
        switch signal {
        case let .naturalLanguage(text, _):
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
    }

    /// Applies a batch of WorldEvents in order.
    public func observe(events: [WorldEvent]) {
        for event in events { worldView.apply(event: event) }
    }

    public func replaceWorldView(_ worldView: WorldView) {
        self.worldView = worldView
    }

    public func worldViewSnapshot() -> WorldView {
        worldView
    }

    public func observe(editSummary: String, revision: UInt64) {
        worldView.apply(editSummary: editSummary, revision: revision)
    }

    public func observe(selectionChanged entityRefs: [String]) {
        worldView.apply(selectionChanged: entityRefs)
    }

    public func entityRecord(ref: String) -> WorldEntityRecord? {
        worldView.entityIndex[ref]
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

        var entitySection = "Scene entities (JSON):\n\(entityIndexJSON())"
        if let note = entityTruncationNote() { entitySection += "\n\n" + note }
        parts.append(entitySection)

        if !worldView.recentEdits.isEmpty {
            let lines = worldView.recentEdits.suffix(10)
                .map { "- \($0.summary) (rev \($0.revision))" }
                .joined(separator: "\n")
            parts.append("Recent edits (most recent last):\n\(lines)")
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

        parts.append("""
        Rules:
        - Only operate on entities that exist in the scene entities list above.
        - Use the exact entity IDs from the list (format: "scene:<number>").
        - Prefer minimal plans — only include steps necessary to satisfy the request.
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
        - If the user asks a general question (capabilities, greetings, clarifications) rather \
        than requesting a scene change, call the tool with an empty steps array and put your \
        conversational reply in the summary field.
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
               "(selected entities and their neighbours are prioritised)."
    }

    private func compactDict(for e: WorldEntityRecord) -> [String: Any] {
        var d: [String: Any] = ["ref": e.ref, "name": e.name]
        if let v = e.kind               { d["kind"] = v }
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
        if let v = e.meshIsVisible, !v  { d["meshIsVisible"] = false }
        if let v = e.animationClip      { d["animationClip"] = v }
        if let v = e.animationSpeed     { d["animationSpeed"] = v }
        if let v = e.animationLoop      { d["animationLoop"] = v }
        if let v = e.animationIsPlaying { d["animationIsPlaying"] = v }
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
    /// Starts at 1.0 and applies penalties:
    /// - Each step beyond the first reduces confidence slightly (large plans are riskier).
    /// - Destructive ops (delete, duplicate) apply a larger penalty.
    /// - Steps that touch many distinct entities are penalised as broad-impact.
    /// - Spawn (createEntity) without a subsequent transform is penalised slightly.
    /// - Empty plans (conversational response) are always 1.0.
    static func confidence(for plan: SceneEditPlan) -> Double {
        guard !plan.steps.isEmpty else { return 1.0 }
        var score = 1.0
        let destructive: Set<SceneEditOp> = [.deleteEntity, .duplicateEntity]
        var affectedEntityIDs = Set<String>()
        var hasSpawn = false

        for (i, step) in plan.steps.enumerated() {
            if i > 0 { score -= 0.03 }
            if destructive.contains(step.op) { score -= 0.10 }
            if step.op == .spawnEntity { hasSpawn = true }
            if let ref = step.entityRef { affectedEntityIDs.insert(ref) }
        }

        // Broad-impact penalty: more than 5 distinct entities touched.
        let broadPenalty = max(0, affectedEntityIDs.count - 5)
        score -= Double(broadPenalty) * 0.02

        // Orphan spawn penalty: spawnEntity with no subsequent setTransform.
        let hasTransformStep = plan.steps.contains { $0.op == .setTransform }
        if hasSpawn && !hasTransformStep { score -= 0.05 }

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
