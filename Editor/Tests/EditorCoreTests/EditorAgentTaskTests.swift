import AIRuntime
import CapabilityRuntime
import Foundation
import Testing
@testable import EditorCore

@Suite("Authoring workflows and agent tasks")
struct EditorAgentTaskTests {
    @Test("Each content offers its own tools")
    func functionalProfiles() {
        let scene = EditorContent.scene.profile
        let files = EditorContent.files.profile
        let timeline = EditorContent.timeline.profile
        #expect(scene.capabilityIDs.contains("scene.set_material"))
        #expect(scene.capabilityIDs.contains("scene.set_script_bindings"))
        #expect(scene.capabilityIDs.contains("scene.set_rigid_body_mass"))
        #expect(scene.projectToolNames.contains("export_project"))
        #expect(files.capabilityIDs.isEmpty)
        #expect(files.projectToolNames.isSuperset(of: ["write_file", "compile_scripts"]))
        #expect(!files.projectToolNames.contains("save_scene"))
        #expect(timeline.projectToolNames.contains("export_media"))
        #expect(!timeline.projectToolNames.contains("compile_scripts"))
    }

    @Test("Capability discovery cannot widen a workflow allow-list")
    func capabilityDiscovery() {
        let profile = EditorContent.scene.profile
        let allowed = profile.capabilityIDs.subtracting(["scene.set_script_bindings", "scene.set_script_property"])
        let policy = CapabilityExposurePolicy(allowedDomains: ["scene"],
            allowedCapabilityIDs: allowed, maximumCapabilities: 100)
        let registry = CapabilityRegistry.aiDefault
        let snapshot = registry.exposureSnapshot(policy: policy)
        #expect(snapshot.contract(id: "scene.set_material") != nil)
        #expect(snapshot.contract(id: "scene.set_script_bindings") == nil)
        // Shared inspector descriptions may match "script"; write access stays scoped.
        #expect(registry.searchContracts(query: "script", policy: policy, limit: 100).allSatisfy { $0.access == .read })
        #expect(snapshot.contracts.allSatisfy { allowed.contains($0.id) })
    }

    @Test("A task keeps its target through selection and workspace changes, and rejects replaced documents")
    func frozenTargetAndLifecycle() throws {
        let service = EditorAgentTaskService()
        let store = EditorStore()
        store.dispatch(.setSceneRevision(7))
        store.dispatch(.setSelectedEntity(42))
        let target = EditorAgentTaskTarget(documentID: store.state.document.identity, sceneRevision: 7,
            content: .scene, selectedEntityIDs: [42], primaryEntityID: 42)
        let task = try #require(service.begin(prompt: "Set material", target: target))
        #expect(service.begin(prompt: "Another task", target: target) == nil)
        store.dispatch(.setSelectedEntity(99))
        store.dispatch(.setContent(.files))
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

    @Test("Content, task sessions and document identity do not persist")
    func sessionPersistenceBoundary() throws {
        var state = EditorState { $0.content = .timeline }
        let target = EditorAgentTaskTarget(documentID: state.document.identity, sceneRevision: 0,
            content: .timeline, selectedEntityIDs: [], primaryEntityID: nil)
        state.assistant.agentTasks = [EditorAgentTask(prompt: "Animate", target: target)]
        let restored = try JSONDecoder().decode(EditorState.self, from: JSONEncoder().encode(state))
        #expect(restored.content == .scene)
        #expect(restored.assistant.agentTasks.isEmpty)
        #expect(restored.document.identity != state.document.identity)
    }

    @Test("Task cancellation and terminal results release the active slot")
    func cancellation() {
        for phase in [EditorAgentTaskPhase.cancelled, .failed, .conflict, .applied, .completed] {
            let service = EditorAgentTaskService()
            let target = EditorAgentTaskTarget(documentID: UUID(), sceneRevision: 1,
                content: .scene, selectedEntityIDs: [], primaryEntityID: nil)
            _ = service.begin(prompt: "Task", target: target)
            service.transition(to: phase, summary: "Result")
            #expect(service.activeTaskID == nil)
            #expect(service.tasks.first?.summary == "Result")
            #expect(service.begin(prompt: "Next", target: target) != nil)
        }
    }
}
