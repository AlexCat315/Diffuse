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

    public var description: String {
        switch self {
        case .missingIntent:
            return "transaction is missing IntentIR"
        case let .approvalForbidden(transactionID):
            return "transaction \(transactionID) is forbidden by approval policy"
        case let .blockedPreconditions(failures):
            return failures.map(\ .message).joined(separator: "; ")
        }
    }
}

public struct CapabilityInvocationPlanner {
    public var registry: CapabilityRegistry
    public var checker: PreconditionChecker

    public init(registry: CapabilityRegistry,
                checker: PreconditionChecker = PreconditionChecker()) {
        self.registry = registry
        self.checker = checker
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
        let preconditionReport = checker.evaluate(resolution.spec.preconditions,
                                                  facts: context.facts,
                                                  currentRole: context.role)
        guard preconditionReport.isAllowed else {
            throw CapabilityInvocationPlannerError.blockedPreconditions(preconditionReport.blockingFailures)
        }

        let confirmationLevel = effectiveConfirmationLevel(capability: resolution.spec.confirmationPolicy.level,
                                                           approvalPolicy: transaction.approvalPolicy)
        let warnings = resolution.warnings + preconditionReport.warnings.map(\ .message)
        let confirmationRequest = makeConfirmationRequest(for: resolution.spec,
                                                          transaction: transaction,
                                                          level: confirmationLevel,
                                                          warnings: warnings)
        return CapabilityInvocationPlan(capability: resolution.spec,
                                        transaction: transaction,
                                        preconditionReport: preconditionReport,
                                        confirmationLevel: confirmationLevel,
                                        confirmationRequest: confirmationRequest,
                                        readAfterWrite: resolution.spec.readAfterWrite,
                                        warnings: warnings)
    }

    private func effectiveConfirmationLevel(capability: CapabilityConfirmationLevel,
                                            approvalPolicy: TransactionApprovalPolicy) -> CapabilityConfirmationLevel {
        let policyLevel: CapabilityConfirmationLevel
        switch approvalPolicy {
        case .automatic:
            policyLevel = .auto
        case .requiresApproval:
            policyLevel = .required
        case .forbidden:
            policyLevel = .destructiveRequired
        }
        return confirmationRank(capability) >= confirmationRank(policyLevel) ? capability : policyLevel
    }

    private func confirmationRank(_ level: CapabilityConfirmationLevel) -> Int {
        switch level {
        case .auto:
            return 0
        case .warn:
            return 1
        case .required:
            return 2
        case .destructiveRequired:
            return 3
        }
    }

    private func makeConfirmationRequest(for capability: CapabilitySpec,
                                         transaction: TransactionIR,
                                         level: CapabilityConfirmationLevel,
                                         warnings: [String]) -> ConfirmationRequestBatch? {
        guard level != .auto else { return nil }
        let question = ConfirmationQuestion(id: "confirm:\(transaction.id)",
                                            kind: level == .destructiveRequired ? .approveDestructive : .chooseOne,
                                            promptShort: transaction.summary,
                                            promptDetail: confirmationPromptDetail(capability: capability,
                                                                                  transaction: transaction,
                                                                                  warnings: warnings),
                                            options: confirmationOptions(for: level),
                                            defaultOptionID: level == .warn ? "confirm" : nil,
                                            severity: confirmationSeverity(for: level),
                                            reversible: capability.reversible,
                                            ambiguityScore: level == .warn ? 0.4 : 0.8,
                                            sourceProposalIDs: [transaction.id])
        return ConfirmationRequestBatch(batchID: "cfm:\(transaction.id)",
                                        origin: "intent_runtime",
                                        correlationID: transaction.id,
                                        questions: [question],
                                        requiredRole: capability.requiredRole)
    }

    private func confirmationPromptDetail(capability: CapabilitySpec,
                                          transaction: TransactionIR,
                                          warnings: [String]) -> String {
        var lines = [
            "verb=\(capability.verbID)",
            "summary=\(transaction.summary)",
        ]
        if !warnings.isEmpty {
            lines.append("warnings=\(warnings.joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }

    private func confirmationOptions(for level: CapabilityConfirmationLevel) -> [ConfirmationOption] {
        switch level {
        case .auto:
            return []
        case .warn:
            return [
                ConfirmationOption(id: "confirm",
                                   labelShort: "Apply",
                                   labelDetail: "Proceed with this transaction"),
                ConfirmationOption(id: "skip",
                                   labelShort: "Skip",
                                   labelDetail: "Leave the staged transaction unapplied"),
            ]
        case .required, .destructiveRequired:
            return [
                ConfirmationOption(id: "confirm",
                                   labelShort: "Confirm",
                                   labelDetail: "Approve this staged transaction"),
                ConfirmationOption(id: "skip",
                                   labelShort: "Skip",
                                   labelDetail: "Discard this staged transaction"),
            ]
        }
    }

    private func confirmationSeverity(for level: CapabilityConfirmationLevel) -> ConfirmationSeverity {
        switch level {
        case .auto:
            return .info
        case .warn, .required:
            return .warn
        case .destructiveRequired:
            return .destructive
        }
    }
}