import CapabilityRuntime
import Foundation
@testable import IntentRuntime
import Testing
import SceneRuntime

@Suite("Commit pipeline")
struct CommitPipelineTests {
    /// Records handler order across @Sendable closures.
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [String] = []
        func record(_ step: String) { lock.withLock { steps.append(step) } }
        func values() -> [String] { lock.withLock { steps } }
    }

    private func transaction(summary: String = "Edit",
                             approvalPolicy: TransactionApprovalPolicy = .automatic,
                             withInvocation: Bool = false) -> TransactionIR {
        TransactionIR(summary: summary,
                      operations: [],
                      capabilityInvocations: withInvocation ? [CapabilityInvocationRecord(
                          capabilityID: "scene.set_name",
                          capabilityVersion: 1,
                          schemaHash: "schema",
                          inputDigest: "digest",
                          access: .reversibleWrite,
                          exposureSnapshotID: UUID())] : [],
                      approvalPolicy: approvalPolicy,
                      provenance: .inferred)
    }

    @Test("handlers run in order and the first denial stops the pipeline")
    func orderedShortCircuit() {
        let trace = Trace()
        let denial = CommitDenial(code: .lockedEntities, reason: "locked entity")
        let pipeline = CommitPipeline(handlers: [
            { request in trace.record("first"); return .proceed(request) },
            { _ in trace.record("second"); return .deny(denial) },
            { request in trace.record("third"); return .proceed(request) },
        ])
        #expect(throws: CommitPipelineError.denied(denial)) {
            try pipeline.run(CommitRequest(transaction: transaction()))
        }
        #expect(trace.values() == ["first", "second"])
    }

    @Test("handlers can rewrite the request and accumulate confirmation material")
    func rewriteAccumulates() throws {
        let question = ConfirmationQuestion(id: "q1",
                                            kind: .approveDestructive,
                                            promptShort: "Apply?",
                                            severity: .warn,
                                            reversible: true,
                                            ambiguityScore: 0.5,
                                            sourceProposalIDs: ["tx"])
        let pipeline = CommitPipeline(handlers: [
            { request in
                var next = request
                next.transaction.summary = "Rewritten"
                next.transaction.approvalPolicy = .requiresApproval
                next.questions.append(question)
                next.warnings.append("ambiguity")
                return .proceed(next)
            },
            { request in
                var next = request
                next.warnings.append("policy")
                return .proceed(next)
            },
        ])
        let outcome = try pipeline.run(CommitRequest(transaction: transaction()))
        #expect(outcome.transaction.summary == "Rewritten")
        #expect(outcome.transaction.approvalPolicy == .requiresApproval)
        #expect(outcome.questions == [question])
        #expect(outcome.warnings == ["ambiguity", "policy"])
    }

    @Test("the standard pipeline requires a capability context for invocation-carrying transactions")
    func standardRequiresContext() throws {
        let pipeline = CommitPipeline.standard(planner: CapabilityInvocationPlanner())
        #expect(throws: IntentRuntimeCoordinatorError.self) {
            try pipeline.run(CommitRequest(transaction: transaction(withInvocation: true)))
        }
        let outcome = try pipeline.run(CommitRequest(transaction: transaction(withInvocation: false)))
        #expect(outcome.transaction.approvalPolicy == .automatic)
        #expect(outcome.questions.isEmpty)
        #expect(outcome.warnings.isEmpty)
    }

    @Test("registered policies run before the standard gates and revoke cleanly")
    func registeredPoliciesRunFirst() async throws {
        let coordinator = IntentRuntimeCoordinator()
        var executionContext = TransactionExecutionContext()
        let invocation = transaction(withInvocation: true)

        // A registered denial wins over the standard missing-context failure,
        // proving entry policies run before the built-in gates.
        let denial = CommitDenial(code: .policy, reason: "blocked by test policy")
        let registration = coordinator.registerCommitPolicy { _ in .deny(denial) }
        #expect(throws: CommitPipelineError.denied(denial)) {
            _ = try coordinator.submitPlan(invocation, executionContext: &executionContext)
        }

        // Revoking restores the standard pipeline's own gate.
        await registration.dispose()
        #expect(throws: IntentRuntimeCoordinatorError.self) {
            _ = try coordinator.submitPlan(invocation, executionContext: &executionContext)
        }
    }

    @Test("the standard pipeline rejects a forbidden policy")
    func standardRejectsForbidden() {
        let pipeline = CommitPipeline.standard(planner: CapabilityInvocationPlanner())
        do {
            _ = try pipeline.run(CommitRequest(transaction: transaction(approvalPolicy: .forbidden)))
            Issue.record("expected forbidden-policy rejection")
        } catch let error as CapabilityInvocationPlannerError {
            guard case .approvalForbidden = error else {
                Issue.record("expected approvalForbidden, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("policy questions force approval even without a capability context")
    func questionsRequireApproval() throws {
        let coordinator = IntentRuntimeCoordinator()
        _ = coordinator.registerCommitPolicy { request in
            var next = request
            next.questions = [ConfirmationQuestion(id: "policy", kind: .chooseOne,
                promptShort: "Review", severity: .info, reversible: true,
                ambiguityScore: 0, sourceProposalIDs: [])]
            return .proceed(next)
        }
        var context = TransactionExecutionContext(sceneRuntime: SceneRuntime())
        let result = try coordinator.submitPlan(transaction(), executionContext: &context)
        #expect(result.disposition == .confirmationRequested)
        #expect(result.confirmationRequest?.questions.map(\.id) == ["policy"])
    }

    @Test("rewritten capability context survives staging and all confirmation questions survive both rounds")
    func rewrittenContextAndQuestionsSurviveConfirmation() throws {
        let descriptor = try #require(CapabilityRegistry.aiDefault.descriptor(for: "scene.get_entities"))
        let transaction = TransactionIR(summary: "Inspect", operations: [],
            capabilityInvocations: [CapabilityInvocationRecord(
                capabilityID: descriptor.verb, capabilityVersion: descriptor.version,
                schemaHash: descriptor.contract.schemaHash, inputDigest: "digest", access: .read,
                exposureSnapshotID: UUID())], approvalPolicy: .automatic, provenance: .inferred)
        let coordinator = IntentRuntimeCoordinator()
        _ = coordinator.registerCommitPolicy { request in
            var next = request
            next.capabilityContext = CapabilityInvocationContext()
            next.questions = [ConfirmationQuestion(id: "scope", kind: .chooseOne,
                promptShort: "Scope?", severity: .info, reversible: true,
                ambiguityScore: 0, sourceProposalIDs: []),
                ConfirmationQuestion(id: "risk", kind: .approveDestructive,
                promptShort: "Risk?", severity: .destructive, reversible: false,
                ambiguityScore: 0, sourceProposalIDs: [])]
            return .proceed(next)
        }
        var context = TransactionExecutionContext(sceneRuntime: SceneRuntime())
        let first = try coordinator.submitPlan(transaction, executionContext: &context)
        let firstRequest = try #require(first.confirmationRequest)
        #expect(firstRequest.questions.map(\.id) == ["scope"])
        func accept(_ request: ConfirmationRequestBatch) -> ConfirmationResolution {
            ConfirmationResolution(batchID: request.batchID, correlationID: request.correlationID,
                answers: request.questions.map { ConfirmationAnswer(questionID: $0.id, outcome: .accepted) },
                partial: false)
        }
        let second = try coordinator.resolvePlanConfirmation(accept(firstRequest), executionContext: &context)
        let secondRequest = try #require(second.confirmationRequest)
        #expect(secondRequest.questions.map(\.id) == ["risk"])
        coordinator.configureCapabilityPlanner(CapabilityInvocationPlanner(registry: CapabilityRegistry()))
        #expect(throws: CapabilityInvocationPlannerError.self) {
            try coordinator.resolvePlanConfirmation(accept(secondRequest), executionContext: &context)
        }
        #expect(coordinator.pendingConfirmationRequest() == nil)
    }
}
