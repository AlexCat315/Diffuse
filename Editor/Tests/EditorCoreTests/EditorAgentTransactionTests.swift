import AIRuntime
import Foundation
import IntentRuntime
import Testing
@testable import EditorCore

@Suite("Agent authoring transactions", .serialized)
struct EditorAgentTransactionTests {
    private func plan(entityID: UInt64) throws -> SceneEditPlan {
        let json: [String: Any] = ["summary": "Rename task target", "steps": [
            ["op": "set_name", "entity_id": "scene:\(entityID)", "name": "Agent Target"],
        ]]
        return try JSONDecoder().decode(SceneEditPlan.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func begin(_ app: EditorApplication, entityID: UInt64, plan: SceneEditPlan) throws {
        let target = EditorAgentTaskTarget(documentID: app.store.state.document.identity,
            sceneRevision: app.store.sceneRevision, workspace: .modeling,
            selectedEntityIDs: [entityID], primaryEntityID: entityID)
        _ = try #require(app.agentTaskService.begin(prompt: "Rename target", target: target))
        app.agentExecution.proposal = Proposal(sessionID: "fixture", semanticIntent: "Rename target", plan: plan)
    }

    @Test("Agent changes use the manual undo history and captured selection after a shell switch")
    @MainActor func sharedHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: true)
        defer { app.shutdown() }
        let entityID = try #require(app.scene.defaultSelectionID)
        let original = try #require(app.scene.entitySummary(id: entityID)?.name)
        let plan = try plan(entityID: entityID)
        try begin(app, entityID: entityID, plan: plan)
        app.store.dispatch(.setSelectedEntity(nil))
        app.store.dispatch(.setWorkspaceMode(.scripting))
        app.store.dispatch(.setInteractionMode(.agent))
        let context = app.makeCapabilityInvocationContext(defaultSource: .ai)
        #expect(context.selectedEntityID == entityID)
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: app.scene.scene,
            baseSceneRevision: app.scene.revision, approvalPolicy: .automatic)
        _ = try app.runPlanTransaction(transaction, capabilityContext: context)
        if app.store.pendingConfirmationRequest != nil { app.acceptPendingConfirmation() }
        #expect(app.agentTaskService.tasks.first?.phase == .applied)
        #expect(app.scene.entitySummary(id: entityID)?.name == "Agent Target")
        #expect(app.canUndo)
        app.undo()
        #expect(app.scene.entitySummary(id: entityID)?.name == original)
    }

    @Test("Review rejects a changed scene, can discard, and document replacement cancels pending tasks")
    @MainActor func staleReviewAndReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: true)
        defer { app.shutdown() }
        let entityID = try #require(app.scene.defaultSelectionID)
        let plan = try plan(entityID: entityID)
        try begin(app, entityID: entityID, plan: plan)
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: app.scene.scene,
            baseSceneRevision: app.scene.revision, approvalPolicy: .requiresApproval)
        _ = try app.runPlanTransaction(transaction, capabilityContext: app.makeCapabilityInvocationContext(defaultSource: .ai))
        #expect(app.agentTaskService.tasks.first?.phase == .awaitingReview)
        #expect(app.scene.renameEntity(entityID, to: "Manual Change"))
        app.acceptPendingConfirmation()
        #expect(app.scene.entitySummary(id: entityID)?.name == "Manual Change")
        #expect(app.store.pendingConfirmationRequest != nil)
        #expect(app.store.aiStatusMessage?.contains("scene changed") == true)
        app.skipPendingConfirmation()
        #expect(app.agentTaskService.tasks.first?.phase == .discarded)
        #expect(app.store.pendingConfirmationRequest == nil)
        try begin(app, entityID: entityID, plan: plan)
        let identity = app.store.state.document.identity
        app.createEmptyScene()
        #expect(app.agentTaskService.tasks.first?.phase == .cancelled)
        #expect(app.store.state.document.identity != identity)
        #expect(app.agentTaskService.activeTask == nil)
    }
}
