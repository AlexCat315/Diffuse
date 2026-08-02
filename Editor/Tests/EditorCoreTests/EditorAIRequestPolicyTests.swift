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

    @Test("unavailable AI rejects submission without consuming the draft")
    func unavailableAIRejectsSubmission() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-ai-unavailable-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let application = try EditorApplication(projectDirectory: project.path)
        defer { application.shutdown() }

        #expect(application.submitNaturalLanguageIntent("keep this draft") == false)
        #expect(application.store.state.chatMessages.isEmpty)
        #expect(application.store.state.aiStatusMessage == "No AI provider configured.")
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

    @Test("quick intents cannot mutate a locked selection")
    func quickIntentHonorsHierarchyLock() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-locked-quick-intent-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let application = try EditorApplication(projectDirectory: project.path)
        defer { application.shutdown() }
        let entityID = try #require(application.store.state.selectedEntityID)
        let originalName = try #require(application.scene.entitySummary(id: entityID)?.name)
        application.scene.setEntityLocked(true, entityIDs: [entityID])
        let lockedRevision = application.scene.revision

        application.submitRenameSelectedEntityIntent(name: "Must Not Apply")

        #expect(application.scene.entitySummary(id: entityID)?.name == originalName)
        #expect(application.scene.revision == lockedRevision)
        #expect(application.store.state.aiStatusMessage?
            .localizedCaseInsensitiveContains("locked") == true)
    }

    @Test("locking a staged plan blocks acceptance but still permits discard")
    func confirmationRechecksHierarchyLock() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-locked-confirmation-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let application = try EditorApplication(projectDirectory: project.path)
        defer { application.shutdown() }
        let entityID = try #require(application.store.state.selectedEntityID)

        application.submitDeleteSelectedEntityIntent()
        #expect(application.store.state.pendingConfirmationRequest != nil)
        application.scene.setEntityLocked(true, entityIDs: [entityID])

        application.acceptPendingConfirmation()

        #expect(application.scene.entitySummary(id: entityID) != nil)
        #expect(application.store.state.pendingConfirmationRequest != nil)
        #expect(application.store.state.aiStatusMessage?
            .localizedCaseInsensitiveContains("locked") == true)

        application.skipPendingConfirmation()

        #expect(application.store.state.pendingConfirmationRequest == nil)
        #expect(application.scene.entitySummary(id: entityID) != nil)
    }

    @Test("scene authoring requests are rejected during playback and pause")
    func playbackRejectsSceneAuthoring() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-playback-authoring-policy-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let application = try EditorApplication(projectDirectory: project.path)
        defer { application.shutdown() }
        let entityID = try #require(application.store.state.selectedEntityID)
        let originalName = try #require(application.scene.entitySummary(id: entityID)?.name)

        application.applyPlaybackState(.playing)
        #expect(!application.submitNaturalLanguageIntent("keep this runtime draft"))
        #expect(application.store.state.chatMessages.isEmpty)
        #expect(application.store.state.aiStatusMessage?
            .localizedCaseInsensitiveContains("stop simulation") == true)
        application.submitRenameSelectedEntityIntent(name: "Runtime Rename")
        #expect(application.scene.entitySummary(id: entityID)?.name == originalName)

        application.applyPlaybackState(.paused)
        application.submitRenameSelectedEntityIntent(name: "Paused Rename")
        #expect(application.scene.entitySummary(id: entityID)?.name == originalName)

        application.applyPlaybackState(.stopped)
        let originalPosition = try #require(application.scene.entityLocalTranslation(entityID))
        let authoredPosition = originalPosition + SIMD3<Float>(1, 2, 3)
        application.scene.setEntityLocalTranslation(entityID, to: authoredPosition)
        #expect(application.scene.entityLocalTranslation(entityID) == authoredPosition)
    }
}
