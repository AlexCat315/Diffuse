import CapabilityRuntime
import Foundation

public struct AmbiguityAssessment: Sendable, Equatable {
    public var confirmationLevel: CapabilityConfirmationLevel
    public var confirmationRequest: ConfirmationRequestBatch?

    public init(confirmationLevel: CapabilityConfirmationLevel,
                confirmationRequest: ConfirmationRequestBatch?) {
        self.confirmationLevel = confirmationLevel
        self.confirmationRequest = confirmationRequest
    }
}

public struct AmbiguityScorer {
    public init() {}

    public func assess(capability: CapabilitySpec,
                       transaction: TransactionIR,
                       approvalPolicy: TransactionApprovalPolicy,
                       warnings: [String]) -> AmbiguityAssessment {
        let confirmationLevel = effectiveConfirmationLevel(capability: capability.confirmationPolicy.level,
                                                           approvalPolicy: approvalPolicy)
        let confirmationRequest = makeConfirmationRequest(for: capability,
                                                          transaction: transaction,
                                                          level: confirmationLevel,
                                                          warnings: warnings)
        return AmbiguityAssessment(confirmationLevel: confirmationLevel,
                                   confirmationRequest: confirmationRequest)
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