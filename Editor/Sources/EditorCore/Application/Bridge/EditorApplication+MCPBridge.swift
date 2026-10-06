import AIRuntime
import ContextMemory
import AssetPipeline
import AudioRuntime
import CapabilityRuntime
import EngineCore
import EngineKernel
import IntentRuntime
import ObservationBus
import PerceptionRuntime
import PluginRuntime
import SemanticPipeline
import RenderBackend
import RHIWGPU
import SceneRuntime
import GuavaUICompose
import GuavaUIRuntime
import Foundation
import SIMDCompat

extension EditorApplication {
    // MARK: - MCP Bridge

    func startMCPBridge() {
        mcpBridge.onCommand = { [weak self] action, params in
            guard let self else { return ["ok": false, "error": "editor unavailable"] }
            if action == "project_tool" {
                do {
                    guard let name = params["tool_name"] as? String,
                          let arguments = params["arguments"] as? [String: Any] else {
                        return ["ok": false, "error": "missing project tool name or arguments"]
                    }
                    let output = try await self.executeProjectTool(
                        name: name, input: JSONSerialization.data(withJSONObject: arguments)
                    )
                    return try JSONSerialization.jsonObject(with: output) as? [String: Any]
                        ?? ["ok": false, "error": "invalid project tool response"]
                } catch { return ["ok": false, "error": error.localizedDescription] }
            }
            return self.handleMCPAction(action, params: params)
        }
        mcpBridge.start()
    }

    private func handleMCPAction(_ action: String, params: [String: Any]) -> [String: Any] {
        switch action {
        case "get_scene":
            return mcpGetScene()
        case "get_context_memory":
            return mcpGetContextMemory(params: params)
        case "get_ai_entity":
            return mcpGetAIEntity(params: params)
        case "get_selection":
            let ref = store.state.selection.selectedEntityID.map { "scene:\($0)" }
            return ["ok": true, "selectedRef": ref as Any]
        case "find_entities":
            return mcpFindEntities(params: params)
        case "open_capability_session":
            return mcpOpenCapabilitySession(params: params)
        case "search_capabilities":
            return mcpSearchCapabilities(params: params)
        case "invoke_capability":
            return mcpInvokeCapability(params: params)
        case "submit_capability_plan":
            return mcpSubmitCapabilityPlan(params: params)
        case "close_capability_session":
            return mcpCloseCapabilitySession(params: params)
        default:
            return ["ok": false, "error": "unknown action '\(action)'"]
        }
    }

    private func mcpOpenCapabilitySession(params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String else {
            return ["ok": false, "error": "missing session_id"]
        }
        let revision = scene.revision
        do {
            let activation = try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                try await mcpCapabilitySessions.bootstrap(sessionID: sessionID,
                                                          sceneRevision: revision)
            }
            return mcpCapabilityActivationResponse(activation)
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    private func mcpSearchCapabilities(params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String else {
            return ["ok": false, "error": "missing session_id"]
        }
        do {
            let input = try mcpValidatedFrameworkInput(
                params,
                capabilityID: "system.search_capabilities"
            )
            let query = input["query"] as? String ?? ""
            let domain = input["domain"] as? String
            let access = (input["access"] as? String).flatMap(CapabilityAccess.init(rawValue:))
            let revision = scene.revision
            let activation = try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                try await mcpCapabilitySessions.search(sessionID: sessionID,
                                                       query: query,
                                                       domain: domain,
                                                       access: access,
                                                       sceneRevision: revision)
            }
            return mcpCapabilityActivationResponse(activation)
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    private func mcpCapabilityActivationResponse(
        _ activation: CapabilitySearchActivation
    ) -> [String: Any] {
        func encode(_ contracts: [CapabilityContract]) -> [[String: Any]] {
            contracts.map { contract in
                [
                    "id": contract.id,
                    "version": contract.version,
                    "tool_name": contract.toolName,
                    "title": contract.title,
                    "description": contract.description,
                    "domain": contract.domain,
                    "access": contract.access.rawValue,
                    "schema_hash": contract.schemaHash,
                    "input_schema": contract.inputSchema.jsonObject(),
                ]
            }
        }
        return [
            "ok": true,
            "snapshot_id": activation.snapshotID.uuidString,
            "active_tool_count": activation.activeToolCount,
            "capabilities": encode(activation.contracts),
            "active_capabilities": encode(activation.activeContracts),
        ]
    }

    private func mcpInvokeCapability(params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String else {
            return ["ok": false, "error": "missing session_id"]
        }
        guard let toolName = params["tool_name"] as? String else {
            return ["ok": false, "error": "missing tool_name"]
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard JSONSerialization.isValidJSONObject(arguments),
              let input = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]) else {
            return ["ok": false, "error": "arguments must be a JSON object"]
        }
        let revision = scene.revision
        do {
            let contract = try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                try await mcpCapabilitySessions.contract(sessionID: sessionID,
                                                         toolName: toolName,
                                                         sceneRevision: revision)
            }
            if contract.access == .read {
                try JSONSchemaValidator.validate(data: input, against: contract.inputSchema)
                if let pluginID = contract.source.pluginID {
                    guard let executor = pluginCapabilityExecutor else {
                        throw EditorPluginCapabilityError.pluginNotEnabled(pluginID)
                    }
                    let querySnapshot = try makePluginQuerySnapshot(
                        pluginID: pluginID,
                        sceneRevision: revision
                    )
                    let payload = try executor.executeRead(
                        toolName: toolName,
                        input: input,
                        snapshot: try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                            try await mcpCapabilitySessions.snapshot(
                                sessionID: sessionID,
                                sceneRevision: revision
                            )
                        },
                        currentSceneRevision: revision,
                        querySnapshot: querySnapshot
                    )
                    let result = try JSONSerialization.jsonObject(with: payload,
                                                                  options: [.fragmentsAllowed])
                    return ["ok": true, "result": result]
                }
                switch contract.id {
                case "scene.get_entities":
                    return mcpGetScene()
                case "scene.get_selection":
                    let ref = store.state.selection.selectedEntityID.map { "scene:\($0)" }
                    return ["ok": true, "selectedRef": ref as Any]
                case "scene.find_entities":
                    return mcpFindEntities(params: arguments)
                default:
                    return [
                        "ok": false,
                        "error": CapabilityExposureSessionError
                            .readCapabilityRequiresHostAdapter(contract.id).description,
                    ]
                }
            }

            let draft = try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                try await mcpCapabilitySessions.createDraft(sessionID: sessionID,
                                                            toolName: toolName,
                                                            input: input,
                                                            sceneRevision: revision)
            }
            return [
                "ok": true,
                "status": "draft_created",
                "draft_id": draft.id.uuidString,
                "capability_id": draft.capabilityID,
                "capability_version": draft.capabilityVersion,
                "schema_hash": draft.schemaHash,
                "scene_revision": draft.sceneRevision,
            ]
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    private func mcpSubmitCapabilityPlan(params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String else {
            return ["ok": false, "error": "missing session_id"]
        }
        do {
            let input = try mcpValidatedFrameworkInput(params,
                                                       capabilityID: "system.submit_plan")
            let summary = input["summary"] as? String ?? "AI capability plan"
            let reasoning = input["reasoning"] as? String
            guard let rawIDs = input["draft_ids"] as? [String],
                  rawIDs.count <= CapabilityDraftLimits.maximumDraftsPerPlan else {
                return [
                    "ok": false,
                    "error": "draft_ids may contain at most \(CapabilityDraftLimits.maximumDraftsPerPlan) ids",
                ]
            }
            let draftIDs = rawIDs.compactMap(UUID.init(uuidString:))
            guard draftIDs.count == rawIDs.count, Set(draftIDs).count == draftIDs.count else {
                return ["ok": false, "error": "draft_ids contains an invalid or duplicate id"]
            }
            let revision = scene.revision
            let validated = try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                try await mcpCapabilitySessions.validatedDrafts(sessionID: sessionID,
                                                                ids: draftIDs,
                                                                sceneRevision: revision)
            }
            let builtInDrafts = validated.drafts.filter { $0.sourcePluginID == nil }
            let plan = try SceneCapabilityDraftLowering.plan(summary: summary,
                                                             reasoning: reasoning,
                                                             drafts: builtInDrafts)
            if validated.drafts.isEmpty {
                return [
                    "ok": true,
                    "status": "no_changes",
                    "summary": plan.summary,
                    "snapshot_id": validated.snapshot.id.uuidString,
                ]
            }
            // The executor prepares each operation against a shadow copy and
            // binds each record to the exact authority snapshot used above.
            let containsPluginDraft = validated.drafts.contains { $0.sourcePluginID != nil }
            let transaction: TransactionIR
            if containsPluginDraft {
                guard let executor = pluginCapabilityExecutor else {
                    throw EditorPluginCapabilityError.pluginNotEnabled(
                        validated.drafts.compactMap(\.sourcePluginID).first ?? "unknown"
                    )
                }
                transaction = try executor.buildTransaction(
                    summary: summary,
                    reasoning: reasoning,
                    drafts: validated.drafts,
                    snapshot: validated.snapshot,
                    scene: scene.scene,
                    currentSceneRevision: revision,
                    querySnapshots: try makePluginQuerySnapshots(
                        for: validated.drafts,
                        sceneRevision: revision
                    ),
                    approvalPolicy: .requiresApproval
                )
            } else {
                transaction = try SceneEditPlanExecutor().buildTransaction(
                    from: plan,
                    scene: scene.scene,
                    baseSceneRevision: revision,
                    approvalPolicy: .requiresApproval,
                    exposureSnapshot: validated.snapshot
                )
            }
            let result = try runPlanTransaction(
                transaction,
                capabilityContext: makeCapabilityInvocationContext(defaultSource: .system)
            )
            try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                try await mcpCapabilitySessions.consume(sessionID: sessionID, ids: draftIDs)
            }
            return [
                "ok": true,
                "summary": plan.summary,
                "transaction_id": result.transactionID,
                "disposition": result.disposition.rawValue,
                "snapshot_id": validated.snapshot.id.uuidString,
            ]
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    private func mcpValidatedFrameworkInput(
        _ params: [String: Any],
        capabilityID: String
    ) throws -> [String: Any] {
        guard let contract = CapabilityRegistry.aiDefault.descriptor(for: capabilityID)?.contract else {
            throw CapabilityDraftError.unknownTool(capabilityID)
        }
        var input = params
        input.removeValue(forKey: "action")
        input.removeValue(forKey: "session_id")
        guard JSONSerialization.isValidJSONObject(input) else {
            throw CapabilityDraftError.invalidInput("input must be a JSON object")
        }
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        try JSONSchemaValidator.validate(data: data, against: contract.inputSchema)
        return input
    }

    private func mcpCloseCapabilitySession(params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String else {
            return ["ok": false, "error": "missing session_id"]
        }
        do {
            try waitForMCPCapabilityResult { [mcpCapabilitySessions] in
                try await mcpCapabilitySessions.removeSession(sessionID)
            }
            return ["ok": true]
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    private func mcpGetScene() -> [String: Any] {
        let snapshot = SceneSemanticEncoder().encode(
            scene.scene,
            selectedEntityID: store.state.selection.selectedEntityID,
            workspaceMode: store.state.workspace.mode.rawValue,
            localeIdentifier: nil
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(snapshot),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return ["ok": false, "error": "scene encoding failed"] }
        return ["ok": true, "scene": json]
    }

    private func mcpFindEntities(params: [String: Any]) -> [String: Any] {
        let nameQuery = (params["name"] as? String)?.lowercased()
        let kindFilter = params["kind"] as? String
        let componentFilter = (params["component"] as? String)?.lowercased()
        let limit = max(1, min((params["limit"] as? Int) ?? 20, 200))
        let nearValues = (params["near_position"] as? [Any])?.compactMap {
            ($0 as? NSNumber)?.doubleValue
        }
        let nearPosition: [Double]? = nearValues?.count == 3 ? nearValues : nil
        let nearRadius = (params["near_radius"] as? NSNumber)?.doubleValue

        let snapshot = SceneSemanticEncoder().encode(
            scene.scene,
            selectedEntityID: store.state.selection.selectedEntityID,
            workspaceMode: store.state.workspace.mode.rawValue,
            localeIdentifier: nil
        )
        var matches: [(entity: SceneSemanticSnapshot.Entity, distance: Double?)] = []
        for entity in snapshot.entities {
            if let nq = nameQuery, !entity.name.lowercased().contains(nq) { continue }
            if let kf = kindFilter, entity.kind != kf { continue }
            if let componentFilter,
               !entity.components.contains(where: { $0.lowercased() == componentFilter }) {
                continue
            }
            var distance: Double?
            if let center = nearPosition, let radius = nearRadius {
                guard let position = entity.worldPosition ?? entity.position,
                      position.count == 3 else { continue }
                let dx = Double(position[0]) - center[0]
                let dy = Double(position[1]) - center[1]
                let dz = Double(position[2]) - center[2]
                let value = (dx * dx + dy * dy + dz * dz).squareRoot()
                guard value <= radius else { continue }
                distance = value
            }
            matches.append((entity, distance))
        }
        if nearPosition != nil {
            matches.sort { ($0.distance ?? .infinity) < ($1.distance ?? .infinity) }
        }
        let results: [[String: Any]] = matches.prefix(limit).map { match in
            var result: [String: Any] = [
                "id": match.entity.id,
                "name": match.entity.name,
                "kind": match.entity.kind,
                "components": match.entity.components,
            ]
            if let position = match.entity.worldPosition ?? match.entity.position {
                result["position"] = position
            }
            if let distance = match.distance { result["distance"] = distance }
            return result
        }
        return ["ok": true, "count": results.count, "entities": results]
    }

    private func mcpGetContextMemory(params: [String: Any]) -> [String: Any] {
        guard let store = contextMemoryStore else {
            return ["ok": false, "error": "context memory is not configured for this project"]
        }
        let budget = params["budget"] as? Int ?? 20
        let semaphore = DispatchSemaphore(value: 0)
        final class State: @unchecked Sendable { var view: [[String: String]] = [] }
        let state = State()
        Task {
            state.view = await store.symbolicView(budget: budget)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 3) == .success else {
            return ["ok": false, "error": "context memory read timed out"]
        }
        return ["ok": true, "entries": state.view, "count": state.view.count]
    }

    private func mcpGetAIEntity(params: [String: Any]) -> [String: Any] {
        let targetRef = (params["entity_id"] as? String) ?? store.state.selection.selectedEntityID.map { "scene:\($0)" }
        guard let targetRef, !targetRef.isEmpty else {
            return ["ok": false, "error": "missing target entity; pass entity_id or select an entity"]
        }
        guard let record = readAIWorldEntityRecord(ref: targetRef) else {
            return ["ok": false, "error": "no AI world record for '\(targetRef)'"]
        }
        return [
            "ok": true,
            "targetRef": targetRef,
            "entity": jsonObject(record) ?? [:],
        ]
    }
}
