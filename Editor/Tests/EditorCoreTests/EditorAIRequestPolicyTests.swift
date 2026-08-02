@testable import EditorCore
import Foundation
import IntentRuntime
import Testing

@Suite("Editor AI request policy")
struct EditorAIRequestPolicyTests {
    @Test("only one AI request may plan at a time")
    func rejectsConcurrentPlanning() {
        #expect(EditorAIRequestPolicy.rejectionMessage(
            hasPendingConfirmation: false,
            requestInFlight: true
        ) == EditorAIRequestPolicy.requestInFlightMessage)
        #expect(EditorAIRequestPolicy.rejectionMessage(
            hasPendingConfirmation: false,
            requestInFlight: false
        ) == nil)
    }

    @Test("pending confirmation remains the highest-priority rejection")
    func pendingConfirmationTakesPriority() {
        #expect(EditorAIRequestPolicy.rejectionMessage(
            hasPendingConfirmation: true,
            requestInFlight: true
        ) == EditorAIRequestPolicy.pendingConfirmationMessage)
        #expect(EditorPlanSubmissionError.pendingConfirmation.errorDescription
            == EditorAIRequestPolicy.pendingConfirmationMessage)
    }

    @Test("human commands cannot accidentally dismiss an AI confirmation")
    func humanCommandPreservesPendingConfirmation() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-ai-request-policy-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let application = try EditorApplication(projectDirectory: project.path)
        defer { application.shutdown() }
        let request = ConfirmationRequestBatch(
            batchID: "batch",
            origin: "test",
            correlationID: "correlation",
            questions: []
        )
        application.store.dispatch(.setPendingConfirmationRequest(request))

        application.submitSpawnEntityIntent(label: "Blocked", position: .zero)

        #expect(application.store.state.pendingConfirmationRequest == request)
        #expect(application.store.state.aiStatusMessage
            == EditorAIRequestPolicy.pendingConfirmationMessage)
    }
}
