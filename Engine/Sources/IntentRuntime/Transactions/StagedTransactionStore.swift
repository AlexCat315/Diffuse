import Foundation
import ObservationBus

public struct StagedTransactionSnapshot: Sendable, Equatable {
    public var transaction: TransactionIR
    public var preview: TransactionPreviewResult
    public var stagedAt: Date

    public init(transaction: TransactionIR,
                preview: TransactionPreviewResult,
                stagedAt: Date = Date()) {
        self.transaction = transaction
        self.preview = preview
        self.stagedAt = stagedAt
    }
}

public struct StageTransactionResult: Sendable, Equatable {
    public var transactionID: String
    public var preview: TransactionPreviewResult

    public init(transactionID: String, preview: TransactionPreviewResult) {
        self.transactionID = transactionID
        self.preview = preview
    }
}

public struct ApplyStagedTransactionResult: Sendable, Equatable {
    public var hadTransaction: Bool
    public var transactionID: String?
    public var applyResult: TransactionApplyResult?

    public init(hadTransaction: Bool,
                transactionID: String? = nil,
                applyResult: TransactionApplyResult? = nil) {
        self.hadTransaction = hadTransaction
        self.transactionID = transactionID
        self.applyResult = applyResult
    }
}

public struct DiscardStagedTransactionResult: Sendable, Equatable {
    public var hadTransaction: Bool
    public var transactionID: String?

    public init(hadTransaction: Bool, transactionID: String? = nil) {
        self.hadTransaction = hadTransaction
        self.transactionID = transactionID
    }
}

public final class StagedTransactionStore: @unchecked Sendable {
    private let executor: TransactionExecutor
    private let lock = NSLock()
    private var staged: StagedTransactionSnapshot?

    public init(executor: TransactionExecutor = TransactionExecutor()) {
        self.executor = executor
    }

    public func stagedTransaction() -> StagedTransactionSnapshot? {
        lock.lock()
        let snapshot = staged
        lock.unlock()
        return snapshot
    }

    public func stage(_ transaction: TransactionIR,
                      from context: TransactionExecutionContext) throws -> StageTransactionResult {
        let preview = try executor.preview(transaction, from: context)
        let snapshot = StagedTransactionSnapshot(transaction: transaction, preview: preview)
        lock.lock()
        staged = snapshot
        lock.unlock()
        try publish(kind: .transactionStaged,
                    transaction: transaction,
                    preview: preview,
                    message: nil,
                    context: context)
        return StageTransactionResult(transactionID: transaction.id, preview: preview)
    }

    public func applyStagedTransaction(to context: inout TransactionExecutionContext) throws -> ApplyStagedTransactionResult {
        lock.lock()
        let snapshot = staged
        lock.unlock()
        guard let snapshot else {
            return ApplyStagedTransactionResult(hadTransaction: false)
        }
        let result = try executor.apply(snapshot.transaction, to: &context)
        lock.lock()
        staged = nil
        lock.unlock()
        return ApplyStagedTransactionResult(hadTransaction: true,
                                            transactionID: snapshot.transaction.id,
                                            applyResult: result)
    }

    public func discardStagedTransaction(using context: TransactionExecutionContext? = nil) throws -> DiscardStagedTransactionResult {
        lock.lock()
        let snapshot = staged
        staged = nil
        lock.unlock()
        guard let snapshot else {
            return DiscardStagedTransactionResult(hadTransaction: false)
        }
        if let context {
            try publish(kind: .transactionDiscarded,
                        transaction: snapshot.transaction,
                        preview: snapshot.preview,
                        message: "discarded",
                        context: context)
        }
        return DiscardStagedTransactionResult(hadTransaction: true,
                                              transactionID: snapshot.transaction.id)
    }

    private func publish(kind: EventKindID,
                         transaction: TransactionIR,
                         preview: TransactionPreviewResult,
                         message: String?,
                         context: TransactionExecutionContext) throws {
        guard let bus = context.observationBus else { return }
        let payload: EventPayloadRecord = [
            "transaction_id": .string(transaction.id),
            "summary": .string(transaction.summary),
            "approval_policy": .string(transaction.approvalPolicy.rawValue),
            "changed_domains": .array(preview.changedDomains.map { .string($0.rawValue) }),
            "created_entity_ids": .array(preview.createdEntityIDs.map { .integer(Int64($0)) }),
            "deleted_entity_ids": .array(preview.deletedEntityIDs.map { .integer(Int64($0)) }),
            "message": message.map(EventValue.string) ?? .null,
        ]
        _ = try bus.publish(kind: kind,
                            streamID: context.transactionStreamID,
                            payload: .inline(payload),
                            origin: context.eventOrigin,
                            causationID: transaction.id,
                            provenance: .authored)
    }
}