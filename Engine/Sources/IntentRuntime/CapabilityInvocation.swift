import CapabilityRuntime
import Foundation
import ObservationBus

public struct CapabilityInvocationContext: Sendable, Equatable {
    public var role: CapabilityRole
    public var releasePhase: ReleasePhase
    public var includeExperimental: Bool
    public var isHotfix: Bool
    public var facts: CapabilityFacts

    public init(role: CapabilityRole,
                releasePhase: ReleasePhase,
                includeExperimental: Bool = false,
                isHotfix: Bool = false,
                facts: CapabilityFacts = CapabilityFacts()) {
        self.role = role
        self.releasePhase = releasePhase
        self.includeExperimental = includeExperimental
        self.isHotfix = isHotfix
        self.facts = facts
    }
}

public enum ConfirmationQuestionKind: String, Sendable, Equatable, Codable {
    case chooseOne = "choose_one"
    case approveDestructive = "approve_destructive"
}

public enum ConfirmationSeverity: String, Sendable, Equatable, Codable {
    case info
    case warn
    case destructive
}

public struct ConfirmationOption: Sendable, Equatable, Codable {
    public var id: String
    public var labelShort: String
    public var labelDetail: String?
    public var sideEffectSummary: String?

    public init(id: String,
                labelShort: String,
                labelDetail: String? = nil,
                sideEffectSummary: String? = nil) {
        self.id = id
        self.labelShort = labelShort
        self.labelDetail = labelDetail
        self.sideEffectSummary = sideEffectSummary
    }
}

public struct ConfirmationQuestion: Sendable, Equatable, Codable {
    public var id: String
    public var kind: ConfirmationQuestionKind
    public var promptShort: String
    public var promptDetail: String?
    public var options: [ConfirmationOption]
    public var defaultOptionID: String?
    public var severity: ConfirmationSeverity
    public var reversible: Bool
    public var ambiguityScore: Double
    public var sourceProposalIDs: [String]

    public init(id: String,
                kind: ConfirmationQuestionKind,
                promptShort: String,
                promptDetail: String? = nil,
                options: [ConfirmationOption] = [],
                defaultOptionID: String? = nil,
                severity: ConfirmationSeverity,
                reversible: Bool,
                ambiguityScore: Double,
                sourceProposalIDs: [String]) {
        self.id = id
        self.kind = kind
        self.promptShort = promptShort
        self.promptDetail = promptDetail
        self.options = options
        self.defaultOptionID = defaultOptionID
        self.severity = severity
        self.reversible = reversible
        self.ambiguityScore = ambiguityScore
        self.sourceProposalIDs = sourceProposalIDs
    }
}

public struct ConfirmationRequestBatch: Sendable, Equatable, Codable {
    public var batchID: String
    public var origin: String
    public var correlationID: String
    public var questions: [ConfirmationQuestion]
    public var contextSnapshotURI: String?
    public var requiredRole: CapabilityRole?

    public init(batchID: String,
                origin: String,
                correlationID: String,
                questions: [ConfirmationQuestion],
                contextSnapshotURI: String? = nil,
                requiredRole: CapabilityRole? = nil) {
        self.batchID = batchID
        self.origin = origin
        self.correlationID = correlationID
        self.questions = questions
        self.contextSnapshotURI = contextSnapshotURI
        self.requiredRole = requiredRole
    }
}

public enum ConfirmationAnswerOutcome: String, Sendable, Equatable, Codable {
    case accepted
    case rejected
    case skipped
    case renamed
    case scoped
    case adjusted
}

public struct ConfirmationAnswer: Sendable, Equatable, Codable {
    public var questionID: String
    public var outcome: ConfirmationAnswerOutcome
    public var pickedOptionID: String?
    public var note: String?

    public init(questionID: String,
                outcome: ConfirmationAnswerOutcome,
                pickedOptionID: String? = nil,
                note: String? = nil) {
        self.questionID = questionID
        self.outcome = outcome
        self.pickedOptionID = pickedOptionID
        self.note = note
    }
}

public struct ConfirmationResolution: Sendable, Equatable, Codable {
    public var batchID: String
    public var correlationID: String
    public var answers: [ConfirmationAnswer]
    public var userID: String?
    public var decidedAt: Date
    public var partial: Bool

    public init(batchID: String,
                correlationID: String,
                answers: [ConfirmationAnswer],
                userID: String? = nil,
                decidedAt: Date = Date(),
                partial: Bool) {
        self.batchID = batchID
        self.correlationID = correlationID
        self.answers = answers
        self.userID = userID
        self.decidedAt = decidedAt
        self.partial = partial
    }
}

public struct CapabilityInvocationPlan: Sendable, Equatable {
    public var capability: CapabilitySpec
    public var transaction: TransactionIR
    public var preconditionReport: PreconditionReport
    public var confirmationLevel: CapabilityConfirmationLevel
    public var confirmationRequest: ConfirmationRequestBatch?
    public var readAfterWrite: [EventKindID]
    public var warnings: [String]

    public init(capability: CapabilitySpec,
                transaction: TransactionIR,
                preconditionReport: PreconditionReport,
                confirmationLevel: CapabilityConfirmationLevel,
                confirmationRequest: ConfirmationRequestBatch?,
                readAfterWrite: [EventKindID],
                warnings: [String]) {
        self.capability = capability
        self.transaction = transaction
        self.preconditionReport = preconditionReport
        self.confirmationLevel = confirmationLevel
        self.confirmationRequest = confirmationRequest
        self.readAfterWrite = readAfterWrite
        self.warnings = warnings
    }

    public var requiresConfirmation: Bool {
        confirmationLevel != .auto
    }
}

public enum CapabilityInvocationPlannerError: Error, CustomStringConvertible {
    case missingIntent
    case approvalForbidden(String)
    case blockedPreconditions([PreconditionFailure])
    case unsupportedProvenance(verbID: String, provenance: TransactionProvenance)

    public var description: String {
        switch self {
        case .missingIntent:
            return "transaction is missing IntentIR"
        case let .approvalForbidden(transactionID):
            return "transaction \(transactionID) is forbidden by approval policy"
        case let .blockedPreconditions(failures):
            return failures.map(\ .message).joined(separator: "; ")
        case let .unsupportedProvenance(verbID, provenance):
            return "capability \(verbID) does not allow transaction provenance \(provenance.rawValue)"
        }
    }
}

public struct CapabilityInvocationPlanner {
    public var registry: CapabilityRegistry
    public var checker: PreconditionChecker
    public var ambiguityScorer: AmbiguityScorer

    public init(registry: CapabilityRegistry,
                checker: PreconditionChecker = PreconditionChecker(),
                ambiguityScorer: AmbiguityScorer = AmbiguityScorer()) {
        self.registry = registry
        self.checker = checker
        self.ambiguityScorer = ambiguityScorer
    }

    public func plan(_ transaction: TransactionIR,
                     context: CapabilityInvocationContext) throws -> CapabilityInvocationPlan {
        guard let intent = transaction.intent else {
            throw CapabilityInvocationPlannerError.missingIntent
        }
        guard transaction.approvalPolicy != .forbidden else {
            throw CapabilityInvocationPlannerError.approvalForbidden(transaction.id)
        }

        let resolution = try registry.resolveInvocation(verbID: intent.verb,
                                                        context: CapabilityQueryContext(role: context.role,
                                                                                        phase: context.releasePhase,
                                                                                        includeExperimental: context.includeExperimental,
                                                                                        isHotfix: context.isHotfix))
        guard resolution.spec.provenanceInputAllowed.contains(CapabilityInputProvenance(rawValue: transaction.provenance.rawValue) ?? .authored) else {
            throw CapabilityInvocationPlannerError.unsupportedProvenance(verbID: resolution.spec.verbID,
                                                                        provenance: transaction.provenance)
        }
        let preconditionReport = checker.evaluate(resolution.spec.preconditions,
                                                  facts: context.facts,
                                                  currentRole: context.role)
        guard preconditionReport.isAllowed else {
            throw CapabilityInvocationPlannerError.blockedPreconditions(preconditionReport.blockingFailures)
        }

        let warnings = resolution.warnings + preconditionReport.warnings.map(\ .message)
        let ambiguity = ambiguityScorer.assess(capability: resolution.spec,
                                               transaction: transaction,
                                               approvalPolicy: transaction.approvalPolicy,
                                               warnings: warnings)
        return CapabilityInvocationPlan(capability: resolution.spec,
                                        transaction: transaction,
                                        preconditionReport: preconditionReport,
                                        confirmationLevel: ambiguity.confirmationLevel,
                                        confirmationRequest: ambiguity.confirmationRequest,
                                        readAfterWrite: resolution.spec.readAfterWrite,
                                        warnings: warnings)
    }
}