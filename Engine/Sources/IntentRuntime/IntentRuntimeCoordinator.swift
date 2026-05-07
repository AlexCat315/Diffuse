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

public final class IntentRuntimeCoordinator: @unchecked Sendable {
    private let planner: CapabilityInvocationPlanner
    private let executor: TransactionExecutor
    private let stagedStore: StagedTransactionStore
    private let naturalLanguageResolver: NaturalLanguageIntentResolver
    private let aiBackend: (any IntentResolverBackend)?
    private let unresolvedQueue: UnresolvableIntentQueue
    private let lock = NSLock()
    private var pendingInvocation: PendingCapabilityInvocation?

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

    public func pendingConfirmationRequest() -> ConfirmationRequestBatch? {
        lock.lock()
        let request = pendingInvocation?.request
        lock.unlock()
        return request
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

    /// AI-backed resolver. Delegates to the injected `IntentResolverBackend` with the full
    /// capability graph as context. Falls back to the deterministic keyword resolver when no
    /// backend was provided at init time, or when the backend call fails.
    public func resolveNaturalLanguageIntentAsync(
        _ naturalLanguageIntent: NaturalLanguageIntent,
        context: NaturalLanguageIntentContext = NaturalLanguageIntentContext(),
        capabilityContext: CapabilityInvocationContext
    ) async -> IntentResolutionResult {
        guard let backend = aiBackend else {
            return resolveNaturalLanguageIntent(naturalLanguageIntent, context: context)
        }

        let capabilities = promptCapabilitySymbolicViews(for: capabilityContext)
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
