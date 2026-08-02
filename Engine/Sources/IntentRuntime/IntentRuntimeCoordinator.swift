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

public enum IntentRuntimeCoordinatorError: Error, CustomStringConvertible, LocalizedError {
    case noPendingConfirmation
    case confirmationBatchMismatch(expected: String, actual: String)
    case incompleteConfirmationAnswers(expected: Int, actual: Int)
    case unexpectedConfirmationQuestion(String)
    case invalidConfirmationOption(questionID: String, optionID: String)
    case missingCapabilityContext

    public var description: String {
        switch self {
        case .noPendingConfirmation:
            return "no confirmation batch is currently staged"
        case let .confirmationBatchMismatch(expected, actual):
            return "confirmation batch mismatch: expected \(expected), actual \(actual)"
        case let .incompleteConfirmationAnswers(expected, actual):
            return "confirmation answers incomplete: expected \(expected), actual \(actual)"
        case let .unexpectedConfirmationQuestion(questionID):
            return "confirmation answer references unexpected question \(questionID)"
        case let .invalidConfirmationOption(questionID, optionID):
            return "confirmation option \(optionID) does not belong to question \(questionID)"
        case .missingCapabilityContext:
            return "capability-backed transactions require an invocation context"
        }
    }

    public var errorDescription: String? { description }
}

private struct PendingInvocation {
    var transaction: TransactionIR
    var request: ConfirmationRequestBatch
    var remainingQuestions: [ConfirmationQuestion]
    var preview: TransactionPreviewResult
    var capabilityContext: CapabilityInvocationContext?
}

public final class IntentRuntimeCoordinator: @unchecked Sendable {
    private let executor: TransactionExecutor
    private let stagedStore: StagedTransactionStore
    private var capabilityPlanner: CapabilityInvocationPlanner
    private let lock = NSLock()
    private var pending: PendingInvocation?

    public let undoStack: UndoStack

    public init(executor: TransactionExecutor = TransactionExecutor(),
                capabilityPlanner: CapabilityInvocationPlanner = CapabilityInvocationPlanner(),
                undoStack: UndoStack = UndoStack()) {
        self.executor = executor
        self.stagedStore = StagedTransactionStore(executor: executor)
        self.capabilityPlanner = capabilityPlanner
        self.undoStack = undoStack
    }

    public func pendingConfirmationRequest() -> ConfirmationRequestBatch? {
        lock.withLock { pending?.request }
    }

    public func configureCapabilityPlanner(_ planner: CapabilityInvocationPlanner) {
        lock.withLock { capabilityPlanner = planner }
    }

    // MARK: - Plan submission

    /// Submits a `TransactionIR`. Confirmation is gated by `transaction.approvalPolicy`:
    /// - `.automatic` → applies immediately
    /// - `.requiresApproval` → stages and returns `.confirmationRequested`
    /// - `.forbidden` → throws
    public func submitPlan(_ transaction: TransactionIR,
                           executionContext: inout TransactionExecutionContext,
                           capabilityContext: CapabilityInvocationContext? = nil) throws -> CapabilityInvocationResult {
        if !transaction.capabilityInvocations.isEmpty, capabilityContext == nil {
            throw IntentRuntimeCoordinatorError.missingCapabilityContext
        }
        var plannedTransaction = transaction
        var plannedQuestions: [ConfirmationQuestion] = []
        var warnings: [String] = []

        if let capabilityContext {
            let planner = lock.withLock { capabilityPlanner }
            let plan = try planner.plan(transaction: plannedTransaction,
                                        context: capabilityContext)
            plannedTransaction.approvalPolicy = plan.approvalPolicy
            plannedQuestions = plan.questions
            warnings = plan.warnings
        }

        return try submitPlannedTransaction(plannedTransaction,
                                            plannedQuestions: plannedQuestions,
                                            warnings: warnings,
                                            capabilityContext: capabilityContext,
                                            executionContext: &executionContext)
    }

    private func submitPlannedTransaction(_ transaction: TransactionIR,
                                          plannedQuestions: [ConfirmationQuestion],
                                          warnings: [String],
                                          capabilityContext: CapabilityInvocationContext?,
                                           executionContext: inout TransactionExecutionContext) throws -> CapabilityInvocationResult {
        guard transaction.approvalPolicy != .forbidden else {
            throw CapabilityInvocationPlannerError.approvalForbidden(transaction.id)
        }

        if transaction.approvalPolicy == .automatic {
            let undoSnapshot = executionContext.sceneRuntime
            let applyResult = try executor.apply(transaction, to: &executionContext)
            if let undoSnapshot { undoStack.push(undoSnapshot) }
            return CapabilityInvocationResult(disposition: .applied,
                                              transactionID: transaction.id,
                                              applyResult: applyResult,
                                              warnings: warnings)
        }

        let stagedResult = try stagedStore.stage(transaction, from: executionContext)
        // AI destructive writes use two separate confirmation rounds: first the
        // whole-plan preview, then the destructive capability warning. Legacy
        // human intents retain their existing single-round questions.
        let destructiveQuestions = transaction.capabilityInvocations.isEmpty
            ? []
            : plannedQuestions.filter { $0.kind == .approveDestructive }
        let initialQuestions = destructiveQuestions.isEmpty ? plannedQuestions : []
        let request = makeConfirmationRequest(for: transaction,
                                              plannedQuestions: initialQuestions)
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
            lock.withLock {
                pending = PendingInvocation(transaction: transaction,
                                            request: request,
                                            remainingQuestions: destructiveQuestions,
                                            preview: stagedResult.preview,
                                            capabilityContext: capabilityContext)
            }
        } catch {
            _ = try? stagedStore.discardStagedTransaction(using: executionContext)
            throw error
        }

        return CapabilityInvocationResult(disposition: .confirmationRequested,
                                          transactionID: transaction.id,
                                          stagedResult: stagedResult,
                                          confirmationRequest: request,
                                          warnings: warnings)
    }

    // MARK: - Undo / Redo

    /// Restores the previous scene snapshot. Returns `true` if a snapshot was available.
    @discardableResult
    public func undo(executionContext: inout TransactionExecutionContext) -> Bool {
        guard let current = executionContext.sceneRuntime,
              let snapshot = undoStack.undo(current: current) else { return false }
        executionContext.sceneRuntime = snapshot
        return true
    }

    /// Re-applies the most recently undone snapshot. Returns `true` if a snapshot was available.
    @discardableResult
    public func redo(executionContext: inout TransactionExecutionContext) -> Bool {
        guard let current = executionContext.sceneRuntime,
              let snapshot = undoStack.redo(current: current) else { return false }
        executionContext.sceneRuntime = snapshot
        return true
    }

    public func resolvePlanConfirmation(_ resolution: ConfirmationResolution,
                                        executionContext: inout TransactionExecutionContext) throws -> CapabilityInvocationResult {
        let p = try lockedPending(for: resolution.batchID)
        try validateConfirmationResolution(resolution, for: p.request)

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
            if !p.remainingQuestions.isEmpty {
                let nextRequest = ConfirmationRequestBatch(
                    batchID: "cfm:destructive:\(p.transaction.id)",
                    origin: "intent_runtime",
                    correlationID: p.transaction.id,
                    questions: p.remainingQuestions
                )
                if let bus = executionContext.observationBus {
                    _ = try bus.publish(kind: .confirmationRequested,
                                        streamID: executionContext.uiStreamID,
                                        payload: .inline(confirmationRequestedPayload(
                                            request: nextRequest,
                                            preview: p.preview
                                        )),
                                        origin: executionContext.eventOrigin,
                                        causationID: p.transaction.id,
                                        correlationID: nextRequest.correlationID,
                                        provenance: .authored)
                }
                lock.withLock {
                    pending = PendingInvocation(transaction: p.transaction,
                                                request: nextRequest,
                                                remainingQuestions: [],
                                                preview: p.preview,
                                                capabilityContext: p.capabilityContext)
                }
                return CapabilityInvocationResult(disposition: .confirmationRequested,
                                                  transactionID: p.transaction.id,
                                                  confirmationRequest: nextRequest)
            }
            // Confirmation may be open while entities, release gates, plugin
            // authorisation, or registry contracts change. Re-run the exact
            // invocation checks against the latest scene immediately before
            // applying the staged transaction.
            if !p.transaction.capabilityInvocations.isEmpty,
               let originalContext = p.capabilityContext {
                var currentContext = originalContext
                if let scene = executionContext.sceneRuntime {
                    currentContext = CapabilityInvocationContext(
                        sceneRuntime: scene,
                        selectedEntityID: originalContext.selectedEntityID,
                        isSceneEditable: originalContext.isSceneEditable,
                        defaultSource: originalContext.defaultSource,
                        defaultConfidence: originalContext.defaultConfidence,
                        defaultEvidence: originalContext.defaultEvidence
                    )
                }
                do {
                    let planner = lock.withLock { capabilityPlanner }
                    _ = try planner.plan(transaction: p.transaction, context: currentContext)
                } catch {
                    _ = try? stagedStore.discardStagedTransaction(using: executionContext)
                    lock.withLock { pending = nil }
                    throw error
                }
            }
            let undoSnapshot = executionContext.sceneRuntime
            let applied = try stagedStore.applyStagedTransaction(to: &executionContext)
            if let undoSnapshot { undoStack.push(undoSnapshot) }
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

    private func makeConfirmationRequest(for transaction: TransactionIR,
                                         plannedQuestions: [ConfirmationQuestion] = []) -> ConfirmationRequestBatch {
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
            questions: plannedQuestions.isEmpty ? [question] : plannedQuestions
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
                "mutations": .array(preview.mutationSummaries.map(EventValue.string)),
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

func validateConfirmationResolution(_ resolution: ConfirmationResolution,
                                    for request: ConfirmationRequestBatch) throws {
    let expectedIDs = Set(request.questions.map(\.id))
    let actualIDs = Set(resolution.answers.map(\.questionID))
    guard resolution.answers.count == request.questions.count,
          actualIDs == expectedIDs else {
        if let unexpected = actualIDs.subtracting(expectedIDs).first {
            throw IntentRuntimeCoordinatorError.unexpectedConfirmationQuestion(unexpected)
        }
        throw IntentRuntimeCoordinatorError.incompleteConfirmationAnswers(
            expected: request.questions.count,
            actual: resolution.answers.count
        )
    }
    let questionsByID = Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, $0) })
    for answer in resolution.answers {
        guard let question = questionsByID[answer.questionID] else {
            throw IntentRuntimeCoordinatorError.unexpectedConfirmationQuestion(answer.questionID)
        }
        if let optionID = answer.pickedOptionID,
           !question.options.contains(where: { $0.id == optionID }) {
            throw IntentRuntimeCoordinatorError.invalidConfirmationOption(
                questionID: answer.questionID,
                optionID: optionID
            )
        }
    }
}
