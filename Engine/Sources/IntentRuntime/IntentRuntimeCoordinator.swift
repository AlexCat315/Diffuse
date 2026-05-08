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

private struct PendingInvocation {
    var transaction: TransactionIR
    var request: ConfirmationRequestBatch
}

public final class IntentRuntimeCoordinator: @unchecked Sendable {
    private let executor: TransactionExecutor
    private let stagedStore: StagedTransactionStore
    private let lock = NSLock()
    private var pending: PendingInvocation?

    public init(executor: TransactionExecutor = TransactionExecutor()) {
        self.executor = executor
        self.stagedStore = StagedTransactionStore(executor: executor)
    }

    public func pendingConfirmationRequest() -> ConfirmationRequestBatch? {
        lock.withLock { pending?.request }
    }

    // MARK: - Plan submission

    /// Submits a `TransactionIR`. Confirmation is gated by `transaction.approvalPolicy`:
    /// - `.automatic` → applies immediately
    /// - `.requiresApproval` → stages and returns `.confirmationRequested`
    /// - `.forbidden` → throws
    public func submitPlan(_ transaction: TransactionIR,
                           executionContext: inout TransactionExecutionContext) throws -> CapabilityInvocationResult {
        guard transaction.approvalPolicy != .forbidden else {
            throw CapabilityInvocationPlannerError.approvalForbidden(transaction.id)
        }

        if transaction.approvalPolicy == .automatic {
            let applyResult = try executor.apply(transaction, to: &executionContext)
            return CapabilityInvocationResult(disposition: .applied,
                                              transactionID: transaction.id,
                                              applyResult: applyResult)
        }

        let stagedResult = try stagedStore.stage(transaction, from: executionContext)
        let request = makeConfirmationRequest(for: transaction)
        do {
            if let bus = executionContext.observationBus {
                _ = try bus.publish(kind: .confirmationRequested,
                                    streamID: executionContext.uiStreamID,
                                    payload: .inline(confirmationRequestedPayload(request: request,
                                                                                  preview: stagedResult.preview)),
                                    origin: executionContext.eventOrigin,
                                    causationID: transaction.id,
                                    correlationID: request.correlationID,
                                    provenance: .authored)
            }
            lock.withLock { pending = PendingInvocation(transaction: transaction, request: request) }
        } catch {
            _ = try? stagedStore.discardStagedTransaction(using: executionContext)
            throw error
        }

        return CapabilityInvocationResult(disposition: .confirmationRequested,
                                          transactionID: transaction.id,
                                          stagedResult: stagedResult,
                                          confirmationRequest: request)
    }

    public func resolvePlanConfirmation(_ resolution: ConfirmationResolution,
                                        executionContext: inout TransactionExecutionContext) throws -> CapabilityInvocationResult {
        let p = try lockedPending(for: resolution.batchID)

        if let bus = executionContext.observationBus {
            _ = try bus.publish(kind: .confirmationResolved,
                                streamID: executionContext.uiStreamID,
                                payload: .inline(confirmationResolvedPayload(resolution: resolution,
                                                                             transactionID: p.transaction.id)),
                                origin: executionContext.eventOrigin,
                                causationID: p.transaction.id,
                                correlationID: resolution.correlationID,
                                provenance: .authored)
        }

        if shouldApply(resolution) {
            let applied = try stagedStore.applyStagedTransaction(to: &executionContext)
            lock.withLock { pending = nil }
            return CapabilityInvocationResult(disposition: .applied,
                                              transactionID: p.transaction.id,
                                              applyResult: applied.applyResult)
        }

        _ = try stagedStore.discardStagedTransaction(using: executionContext)
        lock.withLock { pending = nil }
        return CapabilityInvocationResult(disposition: .discarded,
                                          transactionID: p.transaction.id)
    }

    // MARK: - Private

    private func lockedPending(for batchID: String) throws -> PendingInvocation {
        let p = lock.withLock { pending }
        guard let p else { throw IntentRuntimeCoordinatorError.noPendingConfirmation }
        guard p.request.batchID == batchID else {
            throw IntentRuntimeCoordinatorError.confirmationBatchMismatch(expected: p.request.batchID,
                                                                          actual: batchID)
        }
        return p
    }

    private func makeConfirmationRequest(for transaction: TransactionIR) -> ConfirmationRequestBatch {
        let question = ConfirmationQuestion(
            id: "plan:\(transaction.id)",
            kind: .approveDestructive,
            promptShort: transaction.summary,
            promptDetail: nil,
            options: [
                ConfirmationOption(id: "confirm",
                                   labelShort: "Apply",
                                   labelDetail: "Execute the scene edit plan"),
                ConfirmationOption(id: "skip",
                                   labelShort: "Discard",
                                   labelDetail: "Discard without applying"),
            ],
            defaultOptionID: "confirm",
            severity: .warn,
            reversible: true,
            ambiguityScore: 0.5,
            sourceProposalIDs: [transaction.id]
        )
        return ConfirmationRequestBatch(
            batchID: "cfm:\(transaction.id)",
            origin: "intent_runtime",
            correlationID: transaction.id,
            questions: [question]
        )
    }

    private func shouldApply(_ resolution: ConfirmationResolution) -> Bool {
        guard !resolution.partial, !resolution.answers.isEmpty else { return false }
        return resolution.answers.allSatisfy {
            switch $0.outcome {
            case .accepted, .renamed, .scoped, .adjusted: return true
            case .rejected, .skipped: return false
            }
        }
    }

    private func confirmationRequestedPayload(request: ConfirmationRequestBatch,
                                               preview: TransactionPreviewResult) -> EventPayloadRecord {
        var payload: EventPayloadRecord = [
            "batch_id": .string(request.batchID),
            "origin": .string(request.origin),
            "correlation_id": .string(request.correlationID),
            "questions": .array(request.questions.map(questionPayload)),
            "preview": .object([
                "changed_domains": .array(preview.changedDomains.map { .string($0.rawValue) }),
                "created_entity_ids": .array(preview.createdEntityIDs.map { .integer(Int64($0)) }),
                "deleted_entity_ids": .array(preview.deletedEntityIDs.map { .integer(Int64($0)) }),
            ]),
        ]
        if let uri = request.contextSnapshotURI {
            payload["context_snapshot_uri"] = .string(uri)
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
        if let userID = resolution.userID { payload["user_id"] = .string(userID) }
        return payload
    }

    private func questionPayload(_ q: ConfirmationQuestion) -> EventValue {
        .object([
            "id": .string(q.id),
            "kind": .string(q.kind.rawValue),
            "prompt_short": .string(q.promptShort),
            "prompt_detail": q.promptDetail.map(EventValue.string) ?? .null,
            "options": .array(q.options.map(optionPayload)),
            "default_option": q.defaultOptionID.map(EventValue.string) ?? .null,
            "severity": .string(q.severity.rawValue),
            "reversible": .boolean(q.reversible),
            "ambiguity_score": .number(q.ambiguityScore),
            "source_proposal_ids": .array(q.sourceProposalIDs.map(EventValue.string)),
        ])
    }

    private func optionPayload(_ o: ConfirmationOption) -> EventValue {
        .object([
            "id": .string(o.id),
            "label_short": .string(o.labelShort),
            "label_detail": o.labelDetail.map(EventValue.string) ?? .null,
            "side_effect_summary": o.sideEffectSummary.map(EventValue.string) ?? .null,
        ])
    }

    private func answerPayload(_ a: ConfirmationAnswer) -> EventValue {
        .object([
            "question_id": .string(a.questionID),
            "outcome": .string(a.outcome.rawValue),
            "picked_option_id": a.pickedOptionID.map(EventValue.string) ?? .null,
            "note": a.note.map(EventValue.string) ?? .null,
        ])
    }
}
