import CapabilityRuntime
import Foundation
import ObservationBus

public enum CapabilityInvocationDisposition: String, Sendable, Equatable {
    case applied
    case confirmationRequested = "confirmation_requested"
    case discarded
}

public struct CapabilityInvocationResult: Sendable, Equatable {
    public var disposition: CapabilityInvocationDisposition
    public var transactionID: String
    public var applyResult: TransactionApplyResult?
    public var stagedResult: StageTransactionResult?
    public var confirmationRequest: ConfirmationRequestBatch?
    public var readAfterWrite: [EventKindID]
    public var warnings: [String]

    public init(disposition: CapabilityInvocationDisposition,
                transactionID: String,
                applyResult: TransactionApplyResult? = nil,
                stagedResult: StageTransactionResult? = nil,
                confirmationRequest: ConfirmationRequestBatch? = nil,
                readAfterWrite: [EventKindID] = [],
                warnings: [String] = []) {
        self.disposition = disposition
        self.transactionID = transactionID
        self.applyResult = applyResult
        self.stagedResult = stagedResult
        self.confirmationRequest = confirmationRequest
        self.readAfterWrite = readAfterWrite
        self.warnings = warnings
    }
}

public enum IntentRuntimeCoordinatorError: Error, CustomStringConvertible {
    case noPendingConfirmation
    case confirmationBatchMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .noPendingConfirmation:
            return "no confirmation batch is currently staged"
        case let .confirmationBatchMismatch(expected, actual):
            return "confirmation batch mismatch: expected \(expected), actual \(actual)"
        }
    }
}

private struct PendingCapabilityInvocation {
    var plan: CapabilityInvocationPlan
    var request: ConfirmationRequestBatch
}

/// Staged state for an AI-plan confirmation — does not require a `CapabilitySpec`.
private struct PendingAIPlanInvocation {
    var transaction: TransactionIR
    var request: ConfirmationRequestBatch
}

public final class IntentRuntimeCoordinator: @unchecked Sendable {
    private let planner: CapabilityInvocationPlanner
    private let executor: TransactionExecutor
    private let stagedStore: StagedTransactionStore
    private let naturalLanguageResolver: NaturalLanguageIntentResolver
    private var aiBackend: (any IntentResolverBackend)?
    private let unresolvedQueue: UnresolvableIntentQueue
    private let lock = NSLock()
    private var pendingInvocation: PendingCapabilityInvocation?
    /// Staged confirmation for AI-planner transactions (parallel to `pendingInvocation`).
    private var pendingAIPlanInvocation: PendingAIPlanInvocation?

    public init(registry: CapabilityRegistry,
                checker: PreconditionChecker = PreconditionChecker(),
                executor: TransactionExecutor = TransactionExecutor(),
                naturalLanguageResolver: NaturalLanguageIntentResolver = NaturalLanguageIntentResolver(),
                aiBackend: (any IntentResolverBackend)? = nil,
                unresolvedQueue: UnresolvableIntentQueue = UnresolvableIntentQueue()) {
        self.planner = CapabilityInvocationPlanner(registry: registry, checker: checker)
        self.executor = executor
        self.stagedStore = StagedTransactionStore(executor: executor)
        self.naturalLanguageResolver = naturalLanguageResolver
        self.aiBackend = aiBackend
        self.unresolvedQueue = unresolvedQueue
    }

    public static func `default`() throws -> IntentRuntimeCoordinator {
        IntentRuntimeCoordinator(registry: try CapabilityRegistry.default())
    }

    /// Replaces the active AI backend at runtime. Pass `nil` to disable AI-backed resolution.
    /// Thread-safe; the change is visible to the next call of `resolveNaturalLanguageIntentAsync`.
    public func setBackend(_ backend: (any IntentResolverBackend)?) {
        lock.lock()
        aiBackend = backend
        lock.unlock()
    }

    public func pendingConfirmationRequest() -> ConfirmationRequestBatch? {
        lock.lock()
        let request = pendingInvocation?.request ?? pendingAIPlanInvocation?.request
        lock.unlock()
        return request
    }

    // MARK: - AI plan submission (bypasses CapabilityInvocationPlanner)

    /// Submits an AI-generated `TransactionIR` that has `intent: nil`, bypassing
    /// the capability registry entirely. Confirmation is gated by the transaction's
    /// `approvalPolicy` instead of a registered verb's `confirmationPolicy`.
    ///
    /// - If `approvalPolicy == .automatic`: applies immediately.
    /// - If `approvalPolicy == .requiresApproval`: stages the transaction and returns
    ///   `.confirmationRequested`. Call `resolvePlanConfirmation` to accept or discard.
    /// - `.forbidden` is rejected with an error.
    public func submitPlan(_ transaction: TransactionIR,
                           executionContext: inout TransactionExecutionContext) throws -> CapabilityInvocationResult {
        guard transaction.approvalPolicy != .forbidden else {
            throw CapabilityInvocationPlannerError.approvalForbidden(transaction.id)
        }

        if transaction.approvalPolicy == .automatic {
            let applyResult = try executor.apply(transaction, to: &executionContext)
            return CapabilityInvocationResult(disposition: .applied,
                                              transactionID: transaction.id,
                                              applyResult: applyResult,
                                              readAfterWrite: [],
                                              warnings: [])
        }

        let stagedResult = try stagedStore.stage(transaction, from: executionContext)
        let request = makeAIPlanConfirmationRequest(for: transaction)
        do {
            if let bus = executionContext.observationBus {
                _ = try bus.publish(kind: .confirmationRequested,
                                    streamID: executionContext.uiStreamID,
                                    payload: .inline(aiPlanConfirmationPayload(request: request,
                                                                               preview: stagedResult.preview)),
                                    origin: executionContext.eventOrigin,
                                    causationID: transaction.id,
                                    correlationID: request.correlationID,
                                    provenance: .authored)
            }
            lock.lock()
            pendingAIPlanInvocation = PendingAIPlanInvocation(transaction: transaction, request: request)
            lock.unlock()
        } catch {
            _ = try? stagedStore.discardStagedTransaction(using: executionContext)
            throw error
        }

        return CapabilityInvocationResult(disposition: .confirmationRequested,
                                          transactionID: transaction.id,
                                          stagedResult: stagedResult,
                                          confirmationRequest: request,
                                          readAfterWrite: [],
                                          warnings: [])
    }

    /// Resolves a pending confirmation created by `submitPlan`.
    /// Mirrors `resolveConfirmation` but reads from `pendingAIPlanInvocation`.
    public func resolvePlanConfirmation(_ resolution: ConfirmationResolution,
                                        executionContext: inout TransactionExecutionContext) throws -> CapabilityInvocationResult {
        let pending = try lockedPendingAIPlan(for: resolution.batchID)

        if let bus = executionContext.observationBus {
            _ = try bus.publish(kind: .confirmationResolved,
                                streamID: executionContext.uiStreamID,
                                payload: .inline(confirmationResolvedPayload(resolution: resolution,
                                                                             transactionID: pending.transaction.id)),
                                origin: executionContext.eventOrigin,
                                causationID: pending.transaction.id,
                                correlationID: resolution.correlationID,
                                provenance: .authored)
        }

        if shouldApply(resolution) {
            let applied = try stagedStore.applyStagedTransaction(to: &executionContext)
            clearPendingAIPlan()
            return CapabilityInvocationResult(disposition: .applied,
                                              transactionID: pending.transaction.id,
                                              applyResult: applied.applyResult,
                                              readAfterWrite: [],
                                              warnings: [])
        }

        _ = try stagedStore.discardStagedTransaction(using: executionContext)
        clearPendingAIPlan()
        return CapabilityInvocationResult(disposition: .discarded,
                                          transactionID: pending.transaction.id,
                                          warnings: [])
    }

    public func plan(_ transaction: TransactionIR,
                     capabilityContext: CapabilityInvocationContext) throws -> CapabilityInvocationPlan {
        try planner.plan(transaction, context: capabilityContext)
    }

    public func promptCapabilitySymbolicViews(for capabilityContext: CapabilityInvocationContext,
                                              maxCount: Int? = nil) -> [CapabilitySymbolicView] {
        let query = CapabilityQueryContext(role: capabilityContext.role,
                                           phase: capabilityContext.releasePhase,
                                           includeExperimental: capabilityContext.includeExperimental,
                                           isHotfix: capabilityContext.isHotfix)
        return planner.registry.promptSymbolicViews(for: query, maxCount: maxCount)
    }

    /// Synchronous resolver — uses deterministic keyword matching.
    /// Use `resolveNaturalLanguageIntentAsync` for LLM-backed resolution.
    public func resolveNaturalLanguageIntent(_ naturalLanguageIntent: NaturalLanguageIntent,
                                             context: NaturalLanguageIntentContext = NaturalLanguageIntentContext()) -> IntentResolutionResult {
        let result = naturalLanguageResolver.resolve(naturalLanguageIntent, context: context)
        if let unresolved = result.unresolved {
            _ = unresolvedQueue.append(unresolved)
        }
        return result
    }

    /// Three-layer intent resolution pipeline:
    ///
    /// **Layer 1 — Local classifier** (sync, <5 ms): `LocalIntentClassifier` scores the query
    /// against the registered capability set using weighted token overlap and synonym expansion.
    /// Returns immediately when confidence ≥ threshold; no network call is made.
    ///
    /// **Layer 2 — AI backend** (async, 0.5-2 s): Delegates to the injected
    /// `IntentResolverBackend` with the full capability graph as LLM tool definitions.
    /// Skipped when no backend is configured.
    ///
    /// **Fallback — Keyword resolver** (sync): Deterministic `NaturalLanguageIntentResolver`
    /// used when Layer 1 is below threshold and no AI backend is available, or when the
    /// backend call throws.
    public func resolveNaturalLanguageIntentAsync(
        _ naturalLanguageIntent: NaturalLanguageIntent,
        context: NaturalLanguageIntentContext = NaturalLanguageIntentContext(),
        capabilityContext: CapabilityInvocationContext,
        classifierThreshold: Double = 0.32
    ) async -> IntentResolutionResult {
        let capabilities = promptCapabilitySymbolicViews(for: capabilityContext)

        // Layer 1: local classifier — synchronous, no network
        let classifier = LocalIntentClassifier(confidenceThreshold: classifierThreshold)
        if let l1Result = classifier.classify(naturalLanguageIntent,
                                              context: context,
                                              capabilities: capabilities) {
            if let unresolved = l1Result.unresolved {
                _ = unresolvedQueue.append(unresolved)
            }
            return l1Result
        }

        // Layer 2: AI backend — async, full capability graph
        let backend = lock.withLock { aiBackend }

        guard let backend else {
            return resolveNaturalLanguageIntent(naturalLanguageIntent, context: context)
        }

        do {
            let result = try await backend.resolve(naturalLanguageIntent,
                                                   context: context,
                                                   capabilities: capabilities)
            if let unresolved = result.unresolved {
                _ = unresolvedQueue.append(unresolved)
            }
            return result
        } catch {
            return resolveNaturalLanguageIntent(naturalLanguageIntent, context: context)
        }
    }

    public func unresolvedNaturalLanguageIntents(includeClosed: Bool = false) -> [UnresolvableIntent] {
        unresolvedQueue.snapshot(includeClosed: includeClosed)
    }

    public func dismissUnresolvedIntent(id: String) {
        unresolvedQueue.dismiss(id: id)
    }

    public func markUnresolvedIntentResolved(id: String) {
        unresolvedQueue.markResolved(id: id)
    }

    public func submit(_ transaction: TransactionIR,
                       capabilityContext: CapabilityInvocationContext,
                       executionContext: inout TransactionExecutionContext) throws -> CapabilityInvocationResult {
        let plan = try planner.plan(transaction, context: capabilityContext)
        guard let request = plan.confirmationRequest else {
            let applyResult = try executor.apply(transaction, to: &executionContext)
            return CapabilityInvocationResult(disposition: .applied,
                                              transactionID: transaction.id,
                                              applyResult: applyResult,
                                              readAfterWrite: plan.readAfterWrite,
                                              warnings: plan.warnings)
        }

        let stagedResult = try stagedStore.stage(transaction, from: executionContext)
        do {
            try publishConfirmationRequested(request,
                                             plan: plan,
                                             preview: stagedResult.preview,
                                             context: executionContext)
            lock.lock()
            pendingInvocation = PendingCapabilityInvocation(plan: plan, request: request)
            lock.unlock()
        } catch {
            _ = try? stagedStore.discardStagedTransaction(using: executionContext)
            throw error
        }

        return CapabilityInvocationResult(disposition: .confirmationRequested,
                                          transactionID: transaction.id,
                                          stagedResult: stagedResult,
                                          confirmationRequest: request,
                                          readAfterWrite: plan.readAfterWrite,
                                          warnings: plan.warnings)
    }

    public func resolveConfirmation(_ resolution: ConfirmationResolution,
                                    executionContext: inout TransactionExecutionContext) throws -> CapabilityInvocationResult {
        let pending = try pendingInvocation(for: resolution.batchID)
        try publishConfirmationResolved(resolution,
                                        plan: pending.plan,
                                        context: executionContext)

        if shouldApply(resolution) {
            let applied = try stagedStore.applyStagedTransaction(to: &executionContext)
            clearPendingInvocation()
            return CapabilityInvocationResult(disposition: .applied,
                                              transactionID: pending.plan.transaction.id,
                                              applyResult: applied.applyResult,
                                              readAfterWrite: pending.plan.readAfterWrite,
                                              warnings: pending.plan.warnings)
        }

        _ = try stagedStore.discardStagedTransaction(using: executionContext)
        clearPendingInvocation()
        return CapabilityInvocationResult(disposition: .discarded,
                                          transactionID: pending.plan.transaction.id,
                                          warnings: pending.plan.warnings)
    }

    private func pendingInvocation(for batchID: String) throws -> PendingCapabilityInvocation {
        lock.lock()
        let pending = pendingInvocation
        lock.unlock()
        guard let pending else {
            throw IntentRuntimeCoordinatorError.noPendingConfirmation
        }
        guard pending.request.batchID == batchID else {
            throw IntentRuntimeCoordinatorError.confirmationBatchMismatch(expected: pending.request.batchID,
                                                                         actual: batchID)
        }
        return pending
    }

    private func clearPendingInvocation() {
        lock.lock()
        pendingInvocation = nil
        lock.unlock()
    }

    // MARK: - AI plan confirmation helpers

    private func lockedPendingAIPlan(for batchID: String) throws -> PendingAIPlanInvocation {
        lock.lock()
        let pending = pendingAIPlanInvocation
        lock.unlock()
        guard let pending else {
            throw IntentRuntimeCoordinatorError.noPendingConfirmation
        }
        guard pending.request.batchID == batchID else {
            throw IntentRuntimeCoordinatorError.confirmationBatchMismatch(expected: pending.request.batchID,
                                                                          actual: batchID)
        }
        return pending
    }

    private func clearPendingAIPlan() {
        lock.lock()
        pendingAIPlanInvocation = nil
        lock.unlock()
    }

    private func makeAIPlanConfirmationRequest(for transaction: TransactionIR) -> ConfirmationRequestBatch {
        let question = ConfirmationQuestion(
            id: "ai_plan:\(transaction.id)",
            kind: .approveDestructive,
            promptShort: transaction.summary,
            promptDetail: nil,
            options: [
                ConfirmationOption(id: "confirm",
                                   labelShort: "Apply",
                                   labelDetail: "Execute the AI-generated scene edit plan"),
                ConfirmationOption(id: "skip",
                                   labelShort: "Discard",
                                   labelDetail: "Discard the staged plan without applying"),
            ],
            defaultOptionID: "confirm",
            severity: .warn,
            reversible: true,
            ambiguityScore: 0.5,
            sourceProposalIDs: [transaction.id]
        )
        return ConfirmationRequestBatch(
            batchID: "ai_cfm:\(transaction.id)",
            origin: "ai_runtime",
            correlationID: transaction.id,
            questions: [question]
        )
    }

    private func aiPlanConfirmationPayload(request: ConfirmationRequestBatch,
                                           preview: TransactionPreviewResult) -> EventPayloadRecord {
        var payload: EventPayloadRecord = [
            "batch_id": .string(request.batchID),
            "origin": .string(request.origin),
            "correlation_id": .string(request.correlationID),
            "questions": .array(request.questions.map(questionPayload)),
            "required_role": request.requiredRole.map { .string($0.rawValue) } ?? .null,
            "preview": .object([
                "changed_domains": .array(preview.changedDomains.map { .string($0.rawValue) }),
                "created_entity_ids": .array(preview.createdEntityIDs.map { .integer(Int64($0)) }),
                "deleted_entity_ids": .array(preview.deletedEntityIDs.map { .integer(Int64($0)) }),
            ]),
        ]
        if let contextSnapshotURI = request.contextSnapshotURI {
            payload["context_snapshot_uri"] = .string(contextSnapshotURI)
        }
        return payload
    }

    private func shouldApply(_ resolution: ConfirmationResolution) -> Bool {
        guard !resolution.partial, !resolution.answers.isEmpty else { return false }
        return resolution.answers.allSatisfy { answer in
            switch answer.outcome {
            case .accepted, .renamed, .scoped, .adjusted:
                return true
            case .rejected, .skipped:
                return false
            }
        }
    }

    private func publishConfirmationRequested(_ request: ConfirmationRequestBatch,
                                              plan: CapabilityInvocationPlan,
                                              preview: TransactionPreviewResult,
                                              context: TransactionExecutionContext) throws {
        guard let bus = context.observationBus else { return }
        _ = try bus.publish(kind: .confirmationRequested,
                            streamID: context.uiStreamID,
                            payload: .inline(confirmationRequestedPayload(request: request,
                                                                         plan: plan,
                                                                         preview: preview)),
                            origin: context.eventOrigin,
                            causationID: plan.transaction.id,
                            correlationID: request.correlationID,
                            provenance: .authored)
    }

    private func publishConfirmationResolved(_ resolution: ConfirmationResolution,
                                             plan: CapabilityInvocationPlan,
                                             context: TransactionExecutionContext) throws {
        guard let bus = context.observationBus else { return }
        _ = try bus.publish(kind: .confirmationResolved,
                            streamID: context.uiStreamID,
                            payload: .inline(confirmationResolvedPayload(resolution: resolution,
                                                                        transactionID: plan.transaction.id)),
                            origin: context.eventOrigin,
                            causationID: plan.transaction.id,
                            correlationID: resolution.correlationID,
                            provenance: .authored)
    }

    private func confirmationRequestedPayload(request: ConfirmationRequestBatch,
                                              plan: CapabilityInvocationPlan,
                                              preview: TransactionPreviewResult) -> EventPayloadRecord {
        var payload: EventPayloadRecord = [
            "batch_id": .string(request.batchID),
            "origin": .string(request.origin),
            "correlation_id": .string(request.correlationID),
            "questions": .array(request.questions.map(questionPayload)),
            "required_role": request.requiredRole.map { .string($0.rawValue) } ?? .null,
            "preview": .object([
                "changed_domains": .array(preview.changedDomains.map { .string($0.rawValue) }),
                "created_entity_ids": .array(preview.createdEntityIDs.map { .integer(Int64($0)) }),
                "deleted_entity_ids": .array(preview.deletedEntityIDs.map { .integer(Int64($0)) }),
            ]),
            "read_after_write": .array(plan.readAfterWrite.map { .string($0.rawValue) }),
        ]
        if let contextSnapshotURI = request.contextSnapshotURI {
            payload["context_snapshot_uri"] = .string(contextSnapshotURI)
        }
        return payload
    }

    private func confirmationResolvedPayload(resolution: ConfirmationResolution,
                                             transactionID: String) -> EventPayloadRecord {
        var payload: EventPayloadRecord = [
            "batch_id": .string(resolution.batchID),
            "correlation_id": .string(resolution.correlationID),
            "transaction_id": .string(transactionID),
            "answers": .array(resolution.answers.map(answerPayload)),
            "partial": .boolean(resolution.partial),
            "decided_at_ms": .integer(Int64(resolution.decidedAt.timeIntervalSince1970 * 1000)),
        ]
        if let userID = resolution.userID {
            payload["user_id"] = .string(userID)
        }
        return payload
    }

    private func questionPayload(_ question: ConfirmationQuestion) -> EventValue {
        .object([
            "id": .string(question.id),
            "kind": .string(question.kind.rawValue),
            "prompt_short": .string(question.promptShort),
            "prompt_detail": question.promptDetail.map(EventValue.string) ?? .null,
            "options": .array(question.options.map(optionPayload)),
            "default_option": question.defaultOptionID.map(EventValue.string) ?? .null,
            "severity": .string(question.severity.rawValue),
            "reversible": .boolean(question.reversible),
            "ambiguity_score": .number(question.ambiguityScore),
            "source_proposal_ids": .array(question.sourceProposalIDs.map(EventValue.string)),
        ])
    }

    private func optionPayload(_ option: ConfirmationOption) -> EventValue {
        .object([
            "id": .string(option.id),
            "label_short": .string(option.labelShort),
            "label_detail": option.labelDetail.map(EventValue.string) ?? .null,
            "side_effect_summary": option.sideEffectSummary.map(EventValue.string) ?? .null,
        ])
    }

    private func answerPayload(_ answer: ConfirmationAnswer) -> EventValue {
        .object([
            "question_id": .string(answer.questionID),
            "outcome": .string(answer.outcome.rawValue),
            "picked_option_id": answer.pickedOptionID.map(EventValue.string) ?? .null,
            "note": answer.note.map(EventValue.string) ?? .null,
        ])
    }
}
