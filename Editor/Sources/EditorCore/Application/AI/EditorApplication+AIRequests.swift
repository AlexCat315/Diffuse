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
    /// Starts a natural-language request and reports whether it was accepted.
    /// Callers use the result to avoid discarding the user's draft when a
    /// request is rejected because AI is unavailable, busy, or awaiting review.
    @discardableResult
    public func submitNaturalLanguageIntent(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        guard isSceneAuthoringEnabled else {
            store.dispatch(.setAIStatusMessage(
                "Stop simulation before submitting a scene-editing request."
            ))
            return false
        }

        if let rejection = EditorAIRequestPolicy.rejectionMessage(
            hasPendingConfirmation: store.state.pendingConfirmationRequest != nil,
            requestInFlight: activeAIRequestID != nil
        ) {
            store.dispatch(.setAIStatusMessage(rejection))
            return false
        }

        if let session {
            submitNaturalLanguageIntentWithSession(text, session: session)
            return true
        }

        let message = store.state.aiSettings.provider == .none
            ? "No AI provider configured."
            : "The configured AI provider has no usable credential."
        store.dispatch(.setAIStatusMessage(message))
        return false
    }

    private func submitNaturalLanguageIntentWithSession(_ text: String, session: Session) {
        let locale = store.state.language.lprojName
        let t0 = Date()
        store.dispatch(.setAIStatusMessage("Planning..."))
        store.dispatch(.appendChatMessage(AIChatMessage(role: .user, text: text)))
        let assistantID = UUID().uuidString
        let requestID = UUID()
        activeAIRequestID = requestID
        pendingAssistantMessageID = assistantID
        store.dispatch(.appendChatMessage(AIChatMessage(id: assistantID,
                                                        role: .assistant,
                                                        text: "",
                                                        assistantState: .thinking)))

        let capturedAid = assistantID
        let progressHandler: @Sendable (String) -> Void = { [weak self] partial in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isShuttingDown,
                      self.activeAIRequestID == requestID else { return }
                self.store.dispatch(.updateChatMessage(id: capturedAid,
                                                       assistantState: .streaming(partial)))
            }
        }

        activeAIRequestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.activeAIRequestID == requestID {
                    self.activeAIRequestID = nil
                    self.activeAIRequestTask = nil
                }
            }
            do {
                let proposal = try await session.process(
                    .naturalLanguage(text: text, locale: locale ?? "en"),
                    onProgress: progressHandler
                )
                try Task.checkCancellation()
                guard !self.isShuttingDown,
                      self.activeAIRequestID == requestID else { return }
                let latencyMs = Int(Date().timeIntervalSince(t0) * 1000)

                guard !proposal.plan.isEmpty || !proposal.capabilityDrafts.isEmpty else {
                    self.store.dispatch(.setAIStatusMessage("No scene changes."))
                    if let aid = self.pendingAssistantMessageID {
                        let reply = proposal.plan.summary.isEmpty ? "No scene changes needed." : proposal.plan.summary
                        self.store.dispatch(.updateChatMessage(id: aid,
                                                               assistantState: .replied(reply)))
                        self.pendingAssistantMessageID = nil
                    }
                    await session.recordOutcome(toolUseID: proposal.toolUseID,
                                                content: "Acknowledged.",
                                                proposalID: proposal.id)
                    return
                }

                let containsPluginDraft = proposal.capabilityDrafts.contains {
                    $0.sourcePluginID != nil
                }
                let transaction: TransactionIR
                if containsPluginDraft {
                    guard let executor = self.pluginCapabilityExecutor else {
                        throw EditorPluginCapabilityError.pluginNotEnabled(
                            proposal.capabilityDrafts.compactMap(\.sourcePluginID).first ?? "unknown"
                        )
                    }
                    guard let snapshot = proposal.capabilityExposureSnapshot else {
                        throw EditorPluginCapabilityError.missingExposureSnapshot
                    }
                    let revision = self.scene.revision
                    let querySnapshots = try self.makePluginQuerySnapshots(
                        for: proposal.capabilityDrafts,
                        sceneRevision: revision
                    )
                    transaction = try executor.buildTransaction(
                        summary: proposal.plan.summary,
                        reasoning: proposal.plan.reasoning,
                        drafts: proposal.capabilityDrafts,
                        snapshot: snapshot,
                        scene: self.scene.scene,
                        currentSceneRevision: revision,
                        querySnapshots: querySnapshots,
                        approvalPolicy: proposal.approvalPolicy
                    )
                } else {
                    transaction = try SceneEditPlanExecutor().buildTransaction(
                        from: proposal.plan,
                        scene: self.scene.scene,
                        baseSceneRevision: proposal.baseSceneRevision,
                        approvalPolicy: proposal.approvalPolicy,
                        exposureSnapshot: proposal.capabilityExposureSnapshot
                    )
                }
                self.logConsole("AI inference: \(latencyMs)ms", detail: proposal.plan.summary)
                self.pendingSessionProposal = proposal
                try self.submitPlanTransaction(
                    transaction,
                    capabilityContext: self.makeCapabilityInvocationContext(
                        defaultSource: .ai,
                        defaultConfidence: proposal.confidence
                    )
                )
            } catch {
                guard !self.isShuttingDown,
                      self.activeAIRequestID == requestID else { return }
                let message = error.localizedDescription
                self.pendingSessionProposal = nil
                self.store.dispatch(.setAIStatusMessage(message))
                if let aid = self.pendingAssistantMessageID {
                    self.store.dispatch(.updateChatMessage(id: aid,
                                                           assistantState: .failed(message)))
                    self.pendingAssistantMessageID = nil
                }
            }
        }
    }

    func submitPlanTransaction(_ transaction: TransactionIR,
                                       capabilityContext: CapabilityInvocationContext? = nil) throws {
        _ = try runPlanTransaction(transaction, capabilityContext: capabilityContext)
    }

    @discardableResult
    func runPlanTransaction(_ transaction: TransactionIR,
                                    capabilityContext: CapabilityInvocationContext? = nil) throws -> CapabilityInvocationResult {
        guard store.state.pendingConfirmationRequest == nil else {
            throw EditorPlanSubmissionError.pendingConfirmation
        }
        let targetEntityIDs = referencedExistingEntityIDs(in: transaction)
        let lockedEntityIDs = targetEntityIDs.filter(scene.isEntityLocked).sorted()
        guard lockedEntityIDs.isEmpty else {
            throw EditorPlanSubmissionError.lockedEntities(lockedEntityIDs)
        }

        var context = makeExecutionContext()
        let result = try intentCoordinator.submitPlan(transaction,
                                                      executionContext: &context,
                                                      capabilityContext: capabilityContext)
        if result.disposition == .confirmationRequested {
            pendingConfirmationTargetEntityIDs = targetEntityIDs
        }
        applyInvocationResult(result, executionContext: &context)
        return result
    }

    /// Collects every existing entity whose state or hierarchy the transaction
    /// directly references. Parent IDs matter as well: spawning or moving a child
    /// changes the locked parent's hierarchy even when the child itself is new.
    private func referencedExistingEntityIDs(in transaction: TransactionIR) -> Set<UInt64> {
        var result = Set<UInt64>()

        func insertParent(of rawID: UInt64) {
            guard let entity = entityID(from: rawID),
                  scene.scene.contains(entity),
                  let parent = scene.scene.parent(of: entity) else { return }
            result.insert(parent.rawValue)
        }

        for operation in transaction.operations {
            guard case let .scene(mutation) = operation else { continue }
            if let entityID = mutation.entityID {
                result.insert(entityID)
            }
            switch mutation {
            case let .spawnImportedMeshEntity(_, _, _, _, parentID),
                 let .spawnEmptyEntity(_, _, parentID),
                 let .spawnLightEntity(_, _, _, _, _, _, _, parentID),
                 let .spawnCameraEntity(_, _, _, parentID):
                if let parentID { result.insert(parentID) }
            case let .moveEntity(entityID, parentID, _):
                insertParent(of: entityID)
                if let parentID { result.insert(parentID) }
            case let .deleteEntity(entityID):
                insertParent(of: entityID)
                if let entity = self.entityID(from: entityID), scene.scene.contains(entity) {
                    result.formUnion(scene.scene.children(of: entity).map(\.rawValue))
                }
            default:
                break
            }
        }
        return result
    }

    public func resolvePendingConfirmation(pickedOptionIDsByQuestionID selections: [String: String]) {
        guard let request = store.state.pendingConfirmationRequest,
              !request.questions.isEmpty else {
            store.dispatch(.setAIStatusMessage("No confirmation request is pending."))
            return
        }

        var answers: [ConfirmationAnswer] = []
        for question in request.questions {
            guard let pickedOptionID = selections[question.id],
                  question.options.contains(where: { $0.id == pickedOptionID }) else {
                store.dispatch(.setAIStatusMessage(
                    "Choose an option for every confirmation item before continuing."
                ))
                return
            }
            let normalized = pickedOptionID.lowercased()
            let outcome: ConfirmationAnswerOutcome = ["skip", "discard", "reject", "deny", "cancel"]
                .contains(normalized) ? .skipped : .accepted
            answers.append(ConfirmationAnswer(questionID: question.id,
                                              outcome: outcome,
                                              pickedOptionID: pickedOptionID))
        }
        let resolution = ConfirmationResolution(batchID: request.batchID,
                                                correlationID: request.correlationID,
                                                answers: answers,
                                                userID: "local-editor",
                                                partial: false)
        resolvePendingConfirmation(resolution)
    }

    private func resolvePendingConfirmation(_ resolution: ConfirmationResolution) {
        let lockedEntityIDs = pendingConfirmationTargetEntityIDs
            .filter(scene.isEntityLocked)
            .sorted()
        let acceptsAnyMutation = resolution.answers.contains { $0.outcome == .accepted }
        guard lockedEntityIDs.isEmpty || !acceptsAnyMutation else {
            store.dispatch(.setAIStatusMessage(
                "The pending plan targets locked entities: \(lockedEntityIDs.map(String.init).joined(separator: ", ")). "
                    + "Discard this confirmation, unlock them, and submit the action again."
            ))
            return
        }
        var context = makeExecutionContext()
        do {
            let result = try intentCoordinator.resolvePlanConfirmation(resolution,
                                                                       executionContext: &context)
            applyInvocationResult(result, executionContext: &context)
        } catch {
            store.dispatch(.setAIStatusMessage(error.localizedDescription))
        }
    }

    public func resolvePendingConfirmation(pickedOptionID: String) {
        guard let request = store.state.pendingConfirmationRequest else {
            store.dispatch(.setAIStatusMessage("No confirmation request is pending."))
            return
        }
        let selections: [String: String] = Dictionary(uniqueKeysWithValues: request.questions.compactMap { question in
            guard question.options.contains(where: { $0.id == pickedOptionID }) else { return nil }
            return (question.id, pickedOptionID)
        })
        resolvePendingConfirmation(pickedOptionIDsByQuestionID: selections)
    }

    public func acceptPendingConfirmation() {
        guard let request = store.state.pendingConfirmationRequest else {
            store.dispatch(.setAIStatusMessage("No confirmation request is pending."))
            return
        }
        let selections: [String: String] = Dictionary(uniqueKeysWithValues: request.questions.compactMap { question in
            let optionID = question.defaultOptionID ?? question.options.first?.id
            return optionID.map { (question.id, $0) }
        })
        resolvePendingConfirmation(pickedOptionIDsByQuestionID: selections)
    }

    public func skipPendingConfirmation() {
        guard let request = store.state.pendingConfirmationRequest else {
            store.dispatch(.setAIStatusMessage("No confirmation request is pending."))
            return
        }
        let answers = request.questions.map { question in
            let optionID = question.options.first(where: {
                ["skip", "discard", "reject", "deny", "cancel"].contains($0.id.lowercased())
            })?.id
            return ConfirmationAnswer(questionID: question.id,
                                      outcome: .skipped,
                                      pickedOptionID: optionID)
        }
        resolvePendingConfirmation(ConfirmationResolution(
            batchID: request.batchID,
            correlationID: request.correlationID,
            answers: answers,
            userID: "local-editor",
            partial: false
        ))
    }
}
