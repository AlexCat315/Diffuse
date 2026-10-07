import AIRuntime
import CapabilityRuntime
import Foundation
import Testing

@Suite("AI workflow authority")
struct WorkflowScopeTests {
    @Test("MCP capability search preserves workflow restrictions and never widens domains")
    func boundedDiscovery() async throws {
        let ids: Set<String> = ["scene.get_entities", "scene.get_selection", "scene.find_entities", "scene.set_name"]
        let policy = CapabilityExposurePolicy(allowedDomains: ["scene"], allowedCapabilityIDs: ids)
        let store = CapabilityExposureSessionStore(exposurePolicy: policy)
        let documentID = UUID()
        let sessionID = UUID().uuidString
        await store.setWorkflowScope(policy: policy, documentID: documentID)
        _ = try await store.bootstrap(sessionID: sessionID, sceneRevision: 7)
        let scripts = try await store.search(sessionID: sessionID, query: "script", domain: "scene", sceneRevision: 7)
        #expect(scripts.contracts.isEmpty)
        let renamed = try await store.search(sessionID: sessionID, query: "set_name", domain: "scene", sceneRevision: 7)
        #expect(renamed.contracts.contains { $0.id == "scene.set_name" })
        #expect(renamed.activeContracts.allSatisfy { ids.contains($0.id) })
        let otherDomain = try await store.search(sessionID: sessionID, query: "", domain: "asset", sceneRevision: 7)
        #expect(otherDomain.contracts.isEmpty)
    }

    @Test("Changing workflow or replacing an equal-revision document invalidates old tools")
    func invalidatedAuthority() async throws {
        let policy = CapabilityExposurePolicy(allowedDomains: ["scene"])
        let store = CapabilityExposureSessionStore(exposurePolicy: policy)
        let document = UUID()
        let id = UUID().uuidString
        await store.setWorkflowScope(policy: policy, documentID: document)
        let initial = try await store.bootstrap(sessionID: id, sceneRevision: 1)
        await store.setWorkflowScope(policy: policy, documentID: document)
        #expect(try await store.snapshot(sessionID: id, sceneRevision: 1).id == initial.snapshotID)
        var restricted = policy
        restricted.allowedCapabilityIDs = ["scene.get_entities"]
        await store.setWorkflowScope(policy: restricted, documentID: document)
        await #expect(throws: CapabilityExposureSessionError.sessionNotFound) {
            try await store.snapshot(sessionID: id, sceneRevision: 1)
        }
        _ = try await store.bootstrap(sessionID: id, sceneRevision: 1)
        await store.setWorkflowScope(policy: restricted, documentID: UUID())
        await #expect(throws: CapabilityExposureSessionError.sessionNotFound) {
            try await store.snapshot(sessionID: id, sceneRevision: 1)
        }
    }

    @Test("Asset creation context has its own serialization and no fabricated sequence")
    func assetWorkflow() throws {
        let context = WorkflowContext.asset(AssetWorkflowContext { $0.intent = "Create a reusable prop" })
        let data = try JSONEncoder().encode(context)
        #expect(try JSONDecoder().decode(WorkflowContext.self, from: data) == context)
        #expect(!String(decoding: data, as: UTF8.self).contains("activeSequenceID"))
    }
}
