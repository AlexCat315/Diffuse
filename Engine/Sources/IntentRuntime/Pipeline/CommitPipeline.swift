import CapabilityRuntime
import Foundation

/// Where a submission came from.
///
/// Policies may read the entry to scope their checks; it grants no authority
/// and never substitutes for the standard capability gates.
public enum CommitEntry: Sendable, Equatable {
    case ui
    case mcp(sessionID: String)
    case headless
    case human
}

/// The state threaded through a commit pipeline: the transaction about to be
/// submitted plus the confirmation material capability planning or policy
/// handlers accumulate.
public struct CommitRequest: Sendable {
    public var transaction: TransactionIR
    public var capabilityContext: CapabilityInvocationContext?
    public var entry: CommitEntry
    /// Confirmation questions raised by capability planning or policy.
    public var questions: [ConfirmationQuestion]
    /// Non-blocking warnings surfaced to the caller.
    public var warnings: [String]

    public init(transaction: TransactionIR,
                capabilityContext: CapabilityInvocationContext? = nil,
                entry: CommitEntry = .ui,
                questions: [ConfirmationQuestion] = [],
                warnings: [String] = []) {
        self.transaction = transaction
        self.capabilityContext = capabilityContext
        self.entry = entry
        self.questions = questions
        self.warnings = warnings
    }
}

/// Why a policy refused a submission.
///
/// Existing domain errors keep travelling as thrown values; this is the common
/// shape for policy handlers that do not own a richer error type.
public struct CommitDenial: Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, Equatable {
        case releasePhase
        case precondition
        case pluginAuthority
        case lockedEntities
        case sceneNotEditable
        case busy
        case pendingConfirmation
        case policy
    }

    public var code: Code
    public var reason: String

    public init(code: Code, reason: String) {
        self.code = code
        self.reason = reason
    }

    public var description: String { reason }
}

/// One policy handler's verdict.
public enum CommitDecision: Sendable {
    /// Continue with the (possibly rewritten) request.
    case proceed(CommitRequest)
    /// Stop the pipeline; the submission fails closed.
    case deny(CommitDenial)
}

/// Thrown when a pipeline handler returns `.deny`.
public enum CommitPipelineError: Error, Sendable, Equatable {
    case denied(CommitDenial)
}

extension CommitPipelineError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .denied(denial): return denial.reason
        }
    }
}

extension CommitPipelineError: LocalizedError {
    public var errorDescription: String? { description }
}

/// Ordered policy pipeline every capability submission runs before apply or
/// staging.
///
/// Handlers are pure functions over `CommitRequest` and run in registration
/// order; each may rewrite the request or stop the pipeline with a denial. The
/// built-in order lives in `standard(planner:)`; callers compose their own
/// entry-specific policies with `appending(_:)`.
public struct CommitPipeline: Sendable {
    public typealias Handler = @Sendable (CommitRequest) throws -> CommitDecision

    internal let handlers: [Handler]

    public init(handlers: [Handler] = []) {
        self.handlers = handlers
    }

    public func appending(_ handler: @escaping Handler) -> CommitPipeline {
        CommitPipeline(handlers: handlers + [handler])
    }

    /// Runs every handler in order and returns the final request state. The
    /// first denial stops the pipeline and throws `CommitPipelineError.denied`;
    /// errors thrown by handlers propagate unchanged so existing domain errors
    /// survive the refactor.
    public func run(_ request: CommitRequest) throws -> CommitRequest {
        var current = request
        for handler in handlers {
            switch try handler(current) {
            case let .proceed(next): current = next
            case let .deny(denial): throw CommitPipelineError.denied(denial)
            }
        }
        return current
    }
}

extension CommitPipeline {
    /// The order every submission runs before apply or staging: capability
    /// context requirement, capability planning (release gate, preconditions,
    /// plugin authority, approval escalation), then the forbidden-policy check.
    static func standard(planner: CapabilityInvocationPlanner) -> CommitPipeline {
        CommitPipeline(handlers: [
            requireCapabilityContext,
            planCapabilities(planner),
            rejectForbiddenPolicy,
        ])
    }

    /// Capability-backed transactions must carry the invocation context the
    /// planner and the executor re-validate against.
    private static let requireCapabilityContext: Handler = { request in
        guard request.transaction.capabilityInvocations.isEmpty
                || request.capabilityContext != nil else {
            throw IntentRuntimeCoordinatorError.missingCapabilityContext
        }
        return .proceed(request)
    }

    /// Runs the capability planner and folds its approval policy, questions,
    /// and warnings into the request. Absent a context the transaction is
    /// legacy/human and planning is skipped.
    private static func planCapabilities(_ planner: CapabilityInvocationPlanner) -> Handler {
        { request in
            guard let context = request.capabilityContext else { return .proceed(request) }
            let plan = try planner.plan(transaction: request.transaction, context: context)
            var next = request
            next.transaction.approvalPolicy = plan.approvalPolicy
            next.questions.append(contentsOf: plan.questions)
            next.warnings.append(contentsOf: plan.warnings)
            return .proceed(next)
        }
    }

    private static let rejectForbiddenPolicy: Handler = { request in
        guard request.transaction.approvalPolicy != .forbidden else {
            throw CapabilityInvocationPlannerError.approvalForbidden(request.transaction.id)
        }
        var next = request
        if !next.questions.isEmpty {
            next.transaction.approvalPolicy = .requiresApproval
        }
        return .proceed(next)
    }
}
