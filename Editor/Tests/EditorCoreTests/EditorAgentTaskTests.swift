import AIRuntime
import CapabilityRuntime
import Foundation
import Testing
@testable import EditorCore

@Suite("Authoring workflows and agent tasks")
struct EditorAgentTaskTests {
    @Test("Creation keeps shared authoring tools and animation simulation, without gameplay tools")
    func functionalProfiles() {
        let models = EditorWorkspaceMode.modeling.profile
        let animation = EditorWorkspaceMode.animation.profile
        let game = EditorWorkspaceMode.level.profile
        #expect(models.domain == .creation)
        #expect(models.capabilityIDs.contains("scene.set_material"))
        #expect(!models.capabilityIDs.contains("scene.set_script_bindings"))
        #expect(!models.panelIDs.contains("scripts"))
        #expect(!models.allowsInspectorSection("rigid-body"))
        #expect(animation.allowsInspectorSection("rigid-body"))
        #expect(!animation.allowsInspectorSection("character-controller"))
        #expect(animation.capabilityIDs.contains("scene.set_rigid_body_mass"))
        #expect(!animation.capabilityIDs.contains("scene.set_collider_trigger"))
        #expect(!animation.projectToolNames.contains("export_project"))
        #expect(game.projectToolNames.contains("export_project"))
        #expect(game.capabilityIDs.contains("scene.set_script_bindings"))
    }

    @Test("Capability discovery cannot widen a workflow allow-list")
    func capabilityDiscovery() {
        let profile = EditorWorkspaceMode.modeling.profile
        let policy = CapabilityExposurePolicy(allowedDomains: ["scene"],
            allowedCapabilityIDs: profile.capabilityIDs, maximumCapabilities: 100)
        let registry = CapabilityRegistry.aiDefault
        let snapshot = registry.exposureSnapshot(policy: policy)
        #expect(snapshot.contract(id: "scene.set_material") != nil)
        #expect(snapshot.contract(id: "scene.set_script_bindings") == nil)
        #expect(registry.searchContracts(query: "script", policy: policy, limit: 100).isEmpty)
        #expect(snapshot.contracts.allSatisfy { profile.capabilityIDs.contains($0.id) })
    }

    @Test("A task keeps its target through selection and workspace changes, and rejects replaced documents")
    func frozenTargetAndLifecycle() throws {
        let service = EditorAgentTaskService()
        let store = EditorStore()
        store.dispatch(.setSceneRevision(7))
        store.dispatch(.setSelectedEntity(42))
        let target = EditorAgentTaskTarget(documentID: store.state.document.identity, sceneRevision: 7,
            workspace: .modeling, selectedEntityIDs: [42], primaryEntityID: 42)
        let task = try #require(service.begin(prompt: "Set material", target: target))
        #expect(service.begin(prompt: "Another task", target: target) == nil)
        store.dispatch(.setSelectedEntity(99))
        store.dispatch(.setWorkspaceMode(.scripting))
        store.dispatch(.setInteractionMode(.agent))
        #expect(service.activeTask?.target == target)
        service.transition(to: .awaitingReview, summary: "Change material")
        #expect(service.activeTaskID == task.id)
        #expect(target.matches(documentID: store.state.document.identity, sceneRevision: store.sceneRevision))
        store.dispatch(.beginSceneDocument)
        #expect(!target.matches(documentID: store.state.document.identity, sceneRevision: 7))
        service.transition(to: .discarded)
        #expect(service.activeTask == nil)
        #expect(service.tasks.first?.phase == .discarded)
        #expect(service.begin(prompt: "New task", target: target) != nil)
    }

    @Test("Interaction preferences persist; task sessions and document identity do not")
    func sessionPersistenceBoundary() throws {
        var state = EditorState {
            $0.workspace.mode = .animation
            $0.workspace.layoutPreset = .animationDefault
            $0.workspace.interactionMode = .agent
        }
        let target = EditorAgentTaskTarget(documentID: state.document.identity, sceneRevision: 0,
            workspace: .animation, selectedEntityIDs: [], primaryEntityID: nil)
        state.assistant.agentTasks = [EditorAgentTask(prompt: "Animate", target: target)]
        let restored = try JSONDecoder().decode(EditorState.self, from: JSONEncoder().encode(state))
        #expect(restored.workspace.interactionMode == .agent)
        #expect(restored.workspace.mode == .animation)
        #expect(restored.assistant.agentTasks.isEmpty)
        #expect(restored.document.identity != state.document.identity)
        #expect(try JSONDecoder().decode(EditorWorkspaceState.self, from: Data("{}".utf8)).interactionMode == .manual)
    }

    @Test("Task cancellation and terminal results release the active slot")
    func cancellation() {
        for phase in [EditorAgentTaskPhase.cancelled, .failed, .conflict, .applied, .completed] {
            let service = EditorAgentTaskService()
            let target = EditorAgentTaskTarget(documentID: UUID(), sceneRevision: 1,
                workspace: .level, selectedEntityIDs: [], primaryEntityID: nil)
            _ = service.begin(prompt: "Task", target: target)
            service.transition(to: phase, summary: "Result")
            #expect(service.activeTaskID == nil)
            #expect(service.tasks.first?.summary == "Result")
            #expect(service.begin(prompt: "Next", target: target) != nil)
        }
    }
}
