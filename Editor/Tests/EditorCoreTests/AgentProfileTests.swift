import AIRuntime
import Foundation
import PluginRuntime
import Testing
@testable import EditorCore

@Suite("Agent profiles", .serialized)
@MainActor
struct AgentProfileTests {
    @Test func anAgentNarrowsToolsAndContextButKeepsRespond() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let app = try EditorApplication(projectDirectory: project.path, seedPreviewScene: false,
                                        trustedPluginHostExecutableURL: nil)
        defer { app.shutdown() }
        let target = EditorAgentTaskTarget(documentID: app.store.state.document.identity, sceneRevision: app.store.sceneRevision,
                                           workspace: .level, selectedEntityIDs: [], primaryEntityID: nil)
        let open = app.makeAgentWorkflowScope(target: target)
        #expect(open.agent == SessionAgentContext())
        #expect(open.allowedProjectToolNames == EditorWorkspaceMode.level.profile.projectToolNames)

        app.pluginSession.agents = AgentCatalog(agents: [
            AgentDescriptor(pluginID: "fixture.agents", contribution: AgentContribution(
                id: "reviewer", title: "Reviewer", instructions: "Only review.",
                tools: ["read_file", "scene.set_name", "write_anything"], context: ["selection", "git-summary"])),
            AgentDescriptor(pluginID: "fixture.agents", contribution: AgentContribution(id: "builder", title: "Builder")),
        ])
        let narrowed = app.makeAgentWorkflowScope(target: target)
        #expect(narrowed.allowedCapabilityIDs == ["scene.set_name"])
        #expect(narrowed.allowedProjectToolNames == ["respond"])
        #expect(narrowed.agent.instructions == "Only review.")
        #expect(narrowed.agent.sources == [.selection])

        var settings = app.store.state.assistant.aiSettings
        settings.agentID = "builder"
        app.store.dispatch(.setAISettings(settings))
        #expect(app.makeAgentWorkflowScope(target: target).agent.instructions == nil)
        settings.agentID = "removed"
        app.store.dispatch(.setAISettings(settings))
        #expect(app.makeAgentWorkflowScope(target: target).agent.instructions == "Only review.")
    }

    @Test func agentContextSplitsHostSourcesFromPackageContext() {
        let agent = AgentDescriptor(pluginID: "fixture.agents", contribution: AgentContribution(
            id: "a", title: "A", context: ["scene", "memory", "git-summary"]))
        #expect(agent.hostSources == [.scene, .memory])
        #expect(agent.packageContexts == ["git-summary"])
        let open = AgentDescriptor(pluginID: "fixture.agents", contribution: AgentContribution(id: "b", title: "B"))
        #expect(open.hostSources == nil)
        #expect(open.packageContexts.isEmpty)
    }

    @Test func packageContextIsCutWithoutSplittingAScalar() {
        #expect(EditorApplication.prefix("short", bytes: 16) == "short")
        #expect(EditorApplication.prefix("aé", bytes: 2) == "a")
        #expect(EditorApplication.prefix("aéb", bytes: 3) == "aé")
    }

    @Test func settingsKeepTheChosenAgent() throws {
        let settings = EditorAISettings(providerID: "anthropic", model: "m", agentID: "reviewer")
        let decoded = try JSONDecoder().decode(EditorAISettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        let missing = try JSONDecoder().decode(EditorAISettings.self, from: Data(#"{"provider_id":"anthropic"}"#.utf8))
        #expect(missing.agentID.isEmpty)
    }
}
