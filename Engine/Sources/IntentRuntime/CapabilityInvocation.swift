import Foundation
import ObservationBus

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

    public init(batchID: String,
                origin: String,
                correlationID: String,
                questions: [ConfirmationQuestion],
                contextSnapshotURI: String? = nil) {
        self.batchID = batchID
        self.origin = origin
        self.correlationID = correlationID
        self.questions = questions
        self.contextSnapshotURI = contextSnapshotURI
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

public enum CapabilityInvocationPlannerError: Error, CustomStringConvertible {
    case missingIntent
    case approvalForbidden(String)

    public var description: String {
        switch self {
        case .missingIntent:
            return "transaction is missing IntentIR"
        case let .approvalForbidden(transactionID):
            return "transaction \(transactionID) is forbidden by approval policy"
        }
    }
}
