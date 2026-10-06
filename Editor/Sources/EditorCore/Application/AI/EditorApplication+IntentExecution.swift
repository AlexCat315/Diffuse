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
    public func submitSpawnEntityIntent(label: String,
                                        position: SIMD3<Float>) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLabel = trimmed.isEmpty ? "AI Entity" : trimmed
        let intent = IntentIR(verb: "scene.spawn_entity",
                              summary: "Spawn scene entity",
                              arguments: [
                                "label": .string(resolvedLabel),
                                "position": .vec3(IntentVector3(position)),
                              ],
                              source: .human)
        submitResolvedIntent(intent)
    }

    public func submitRenameSelectedEntityIntent(name: String) {
        guard let selected = store.state.selection.selectedEntityID,
              scene.entitySummary(id: selected) != nil
        else {
            store.dispatch(.setAIStatusMessage("Select an entity before renaming it."))
            return
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            store.dispatch(.setAIStatusMessage("Enter a name before renaming the selection."))
            return
        }

        let intent = IntentIR(verb: "scene.set_name",
                              summary: "Rename selected entity",
                              targetObjectIDs: ["scene:\(selected)"],
                              arguments: ["name": .string(trimmed)],
                              source: .human)
        submitResolvedIntent(intent)
    }

    public func submitDuplicateSelectedEntityIntent() {
        guard let selected = store.state.selection.selectedEntityID,
              scene.entitySummary(id: selected) != nil
        else {
            store.dispatch(.setAIStatusMessage("Select an entity before duplicating it."))
            return
        }

        let intent = IntentIR(verb: "scene.duplicate_entity",
                              summary: "Duplicate selected entity",
                              targetObjectIDs: ["scene:\(selected)"],
                              source: .human)
        submitResolvedIntent(intent)
    }

    public func submitDeleteSelectedEntityIntent() {
        guard let selected = store.state.selection.selectedEntityID,
              scene.entitySummary(id: selected) != nil
        else {
            store.dispatch(.setAIStatusMessage("Select an entity before deleting it."))
            return
        }
        let intent = IntentIR(verb: "scene.delete_entity",
                              summary: "Delete selected entity",
                              targetObjectIDs: ["scene:\(selected)"],
                              source: .human)
        submitResolvedIntent(intent)
    }

    public func submitSetTransformIntent(translation: SIMD3<Float>) {
        guard let selected = store.state.selection.selectedEntityID,
              entityID(from: selected) != nil
        else {
            store.dispatch(.setAIStatusMessage("Select an entity before setting its transform."))
            return
        }
        let intent = IntentIR(verb: "scene.set_transform",
                              summary: "Set selected transform",
                              targetObjectIDs: ["scene:\(selected)"],
                              arguments: ["translation": .vec3(IntentVector3(translation))],
                              source: .human)
        submitResolvedIntent(intent)
    }

    static func makeCapabilityInvocationPlanner(
        for settings: EditorCapabilitySettings,
        pluginCapabilityExecutor: PluginCapabilityExecutor? = nil
    ) -> CapabilityInvocationPlanner {
        let gate = ReleasePhaseGate(activePhase: settings.releasePhase.runtimePhase)
        return pluginCapabilityExecutor?.makeInvocationPlanner(gate: gate)
            ?? CapabilityInvocationPlanner(gate: gate)
    }

    private func submitResolvedIntent(_ intent: IntentIR) {
        do {
            let transaction = try intentTransactionBuilder.buildTransaction(from: intent,
                                                                            context: makeIntentTransactionBuildContext())
            try submitPlanTransaction(
                transaction,
                capabilityContext: makeCapabilityInvocationContext(
                    defaultSource: intent.source,
                    defaultConfidence: intent.confidence,
                    defaultEvidence: intent.evidence
                )
            )
        } catch EditorPlanSubmissionError.pendingConfirmation {
            store.dispatch(.setAIStatusMessage(
                EditorAIRequestPolicy.pendingConfirmationMessage
            ))
        } catch {
            store.dispatch(.setPendingConfirmationRequest(nil))
            store.dispatch(.setAIWarnings([]))
            store.dispatch(.setAIStatusMessage(error.localizedDescription))
        }
    }

    private func makeIntentTransactionBuildContext() -> IntentTransactionBuildContext {
        IntentTransactionBuildContext(sceneRuntime: scene.scene,
                                      selectedEntityID: store.state.selection.selectedEntityID,
                                      defaultSpawnMeshIndex: defaultSpawnMeshIndex())
    }

    func makeCapabilityInvocationContext(defaultSource: IntentSource = .system,
                                                 defaultConfidence: Double = 1.0,
                                                 defaultEvidence: [IntentEvidence] = []) -> CapabilityInvocationContext {
        CapabilityInvocationContext(sceneRuntime: scene.scene,
                                    selectedEntityID: store.state.selection.selectedEntityID,
                                    isSceneEditable: store.state.timing.playbackState == .stopped,
                                    defaultSource: defaultSource,
                                    defaultConfidence: defaultConfidence,
                                    defaultEvidence: defaultEvidence)
    }

    func applyInvocationResult(_ result: CapabilityInvocationResult,
                                       executionContext: inout TransactionExecutionContext) {
        if let updatedScene = executionContext.sceneRuntime {
            scene.scene = updatedScene
            scene.notifyRevisionChanged()
        }

        switch result.disposition {
        case .applied:
            pendingConfirmationTargetEntityIDs.removeAll()
            store.dispatch(.setPendingConfirmationRequest(nil))
            store.dispatch(.setAIWarnings(result.warnings))
            updateSelection(after: result.applyResult)
            store.dispatch(.setAIStatusMessage("Applied \(result.transactionID)"))
            if let aid = pendingAssistantMessageID {
                let planSummary = pendingSessionProposal?.plan.summary ?? ""
                let appliedSummary = planSummary.isEmpty ? "Applied" : planSummary
                store.dispatch(.updateChatMessage(id: aid, assistantState: .applied(summary: appliedSummary)))
                pendingAssistantMessageID = nil
            }
            if var edit = result.applyResult?.edit {
                // Enrich provenance with the proposal that generated this edit.
                if let proposal = pendingSessionProposal {
                    edit.provenance.proposalID = proposal.id
                    let acceptedStepIDs = (0..<proposal.plan.steps.count).map { "step_\($0)" }
                    if let session {
                        Task {
                            _ = try? await session.process(
                                .userCorrection(proposalID: proposal.id,
                                               acceptedStepIDs: acceptedStepIDs,
                                               rejectedStepIDs: [])
                            )
                        }
                    }
                    pendingSessionProposal = nil
                }
                do {
                    try editLog.append(edit)
                } catch {
                    logConsole("Failed to record applied edit",
                               severity: .error,
                               detail: "\(edit.id): \(error)")
                }
            }
            if let events = result.applyResult?.worldEvents, !events.isEmpty {
                observeWorldEvents(events)
            }
        case .confirmationRequested:
            store.dispatch(.setPendingConfirmationRequest(result.confirmationRequest))
            store.dispatch(.setAIWarnings(result.warnings))
            store.dispatch(.setAIStatusMessage("Confirmation required for \(result.transactionID)"))
            if let aid = pendingAssistantMessageID {
                let prompt = result.confirmationRequest?.questions.first?.promptShort ?? "Confirmation required"
                store.dispatch(.updateChatMessage(id: aid, assistantState: .pendingConfirmation(summary: prompt)))
            }
        case .discarded:
            pendingConfirmationTargetEntityIDs.removeAll()
            store.dispatch(.setPendingConfirmationRequest(nil))
            store.dispatch(.setAIWarnings(result.warnings))
            store.dispatch(.setAIStatusMessage("Discarded \(result.transactionID)"))
            if let aid = pendingAssistantMessageID {
                store.dispatch(.updateChatMessage(id: aid, assistantState: .discarded))
                pendingAssistantMessageID = nil
            }
            if let proposal = pendingSessionProposal {
                if let session {
                    Task { await session.recordOutcome(
                        toolUseID: proposal.toolUseID,
                        content: "User rejected this plan.",
                        proposalID: proposal.id
                    ) }
                }
                pendingSessionProposal = nil
            }
        }
    }

    func makeExecutionContext() -> TransactionExecutionContext {
        TransactionExecutionContext(sceneRuntime: scene.scene,
                                    observationBus: observationBus,
                                    eventOrigin: EventOrigin(process: .editor,
                                                             host: "local-editor",
                                                             user: "local-user"))
    }

    private func updateSelection(after applyResult: TransactionApplyResult?) {
        if let created = applyResult?.createdEntityIDs.first {
            store.dispatch(.setSelectedEntity(created))
            return
        }
        guard let applyResult else { return }
        if let selected = store.state.selection.selectedEntityID,
           applyResult.deletedEntityIDs.contains(selected) {
            store.dispatch(.setSelectedEntity(nil))
        }
    }

    private func defaultSpawnMeshIndex() -> Int {
        guard let entity = entityID(from: store.state.selection.selectedEntityID),
              let mesh = scene.scene.component(RenderMeshComponent.self, for: entity)
        else {
            return 0
        }
        return mesh.meshIndex
    }

    func entityID(from rawID: UInt64?) -> EntityID? {
        guard let rawID else { return nil }
        return EntityID(index: UInt32(rawID & 0xFFFF_FFFF),
                        generation: UInt32(rawID >> 32))
    }
}
