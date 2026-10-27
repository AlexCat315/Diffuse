@testable import EditorUI
@testable import EditorCore
import PluginRuntime
import IntentRuntime
import Foundation
import CoveUICompose
import CoveUIRuntime
import CoveUIWorkspace
import Testing

/// The agent is a plugin. When it is disabled, nothing it contributed may
/// remain reachable — not the view, not the switch, not a menu, not a shortcut
/// and not a pending review. These tests pin that at the level the user sees:
/// the rendered window and the command catalog.
@Suite("Agent plugin surface", .serialized)
@MainActor
struct AgentPluginSurfaceTests {
    /// Loads the bundled agent the way launch does, without a host process.
    private static func loadAgent(in app: EditorApplication) throws {
        let plugin = try #require(BundledPlugins.plugin(id: "studio.ai"))
        let package = try PluginPackageLoader().load(at: plugin.package)
        app.pluginSession.providers = AIProviderCatalog(packages: [package])
        app.pluginSession.agents = AgentCatalog(packages: [package])
        app.pluginSession.editor.workbench.replace(WorkbenchCatalog(packages: [package]))
    }

    private func makeApp() throws -> (app: EditorApplication, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: true)
        return (app, directory)
    }

    @Test("disabling the agent plugin leaves nothing of it in the window")
    func disabledAgentLeavesNothing() throws {
        try WorkbenchUITestSupport.withEnvironment { _, _ in
            let (app, directory) = try makeApp()
            defer {
                app.shutdown()
                try? FileManager.default.removeItem(at: directory)
            }

            // Start from a loaded agent, so this proves the transition rather
            // than an environment that never had one.
            try Self.loadAgent(in: app)
            #expect(!app.workbenchCatalog.panels.isEmpty)
            // The view exists because the package declared a panel for it, and
            // its label is the contribution's title — no editor-side flag, and
            // no editor-side name for another plugin's view.
            #expect(app.studioViews == [.make, EditorStudioView("studio.ai.assistant")])
            #expect(app.studioViewSegments.first?.view == .make)
            #expect(app.studioViewSegments.last?.title == "AI")
            let surface = EditorAssistantSurface.of(app)
            surface.show(.agent)
            #expect(surface.view == EditorStudioView("studio.ai.assistant"))

            // Disable it the way the plugin manager does: the contributions go,
            // and the view goes with them.
            app.pluginSession.agents = .empty
            app.pluginSession.editor.workbench.replace(.empty)
            app.rebuildAgentSurfaces()

            #expect(!app.isAgentEnabled)
            #expect(!app.isAIAvailable)
            #expect(app.session == nil)
            #expect(app.studioViews == [.make])
            // The requested view cannot outlive the package that declared it.
            #expect(surface.view == .make)
            surface.show(.agent)
            #expect(surface.view == .make, "a view no package declares cannot be asked for")

            // No menu title, no entry, no shortcut into an empty view.
            let catalog = EditorCommandCatalog.make(EditorCommandContext(app: app))
            #expect(!catalog.menus.contains { $0.id == "agent" })
            let entries: [EditorCommandEntry] = catalog.menus.flatMap(\.items).compactMap {
                if case let .entry(entry) = $0 { return entry }
                return nil
            }
            #expect(!entries.contains { $0.id.hasPrefix("agent.") })
            #expect(!entries.contains { $0.id == "view.toggle" })

            // And the window renders the workbench with no agent chrome.
            let registry = EditorRootViewFactory.makeRegistry(app: app)
            let document = EditorWorkspaceDefaults.makeDocument(registry: registry)
            let controller = WorkspaceController(document: document)
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: EditorRootView(app: app, controller: controller, registry: registry))
            for _ in 0..<3 { graph.recomposer.commitAll() }
            graph.computeLayout(width: 1280, height: 800)
            let frames = graph.layoutSnapshot()
            #expect(!frames.contains { $0.debugName == "editor-view-switch" })
            #expect(!frames.contains { $0.debugName == "editor-agent-view" })
            #expect(!frames.contains { $0.debugName == "editor-agent-thread" })
            #expect(!frames.contains { $0.debugName == "editor-agent-composer" })
            #expect(frames.contains { $0.debugName == "editor-workspace" })
            // The content picker belongs to the workbench; it must not be lost
            // because a stale agent view was left in front.
            #expect(frames.contains { $0.debugName == "editor-content-picker" })
        }
    }

    @Test("third parties provide whole surfaces without editor implementation")
    func thirdPartySurfaceIsOffered() throws {
        let (app, directory) = try makeApp()
        defer {
            app.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }

        // Same shape as the AI package, but another plugin and a view name the
        // editor does not implement. No `isXxxEnabled` flag is involved either
        // way: the answer comes from the contribution.
        let source = try #require(BundledPlugins.plugin(id: "studio.ai")).package
        let packageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).coveplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: packageDirectory) }
        try FileManager.default.removeItem(at: packageDirectory)
        try FileManager.default.copyItem(at: source, to: packageDirectory)
        var manifest = try String(contentsOf: source.appendingPathComponent("plugin.json"), encoding: .utf8)
        manifest = manifest.replacingOccurrences(of: "studio.ai", with: "studio.swift-playground")
        manifest = manifest.replacingOccurrences(of: "\"surface\": \"assistant\"", with: "\"surface\": \"playground\"")
        manifest = manifest.replacingOccurrences(of: "studio.swift-playground.assistant", with: "studio.swift-playground.playground")
        manifest = manifest.replacingOccurrences(of: "\"title\": \"AI\"", with: "\"title\": \"Playground\"")
        try manifest.write(to: packageDirectory.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        let package = try PluginPackageLoader().load(at: packageDirectory)

        app.pluginSession.editor.workbench.replace(WorkbenchCatalog(packages: [package]))

        // The contribution is kept — it is still a panel — but it never becomes
        // a top-level segment, because nothing here can draw it.
        #expect(app.workbenchCatalog.panels.count == 3)
        #expect(app.studioViews == [.make, EditorStudioView("studio.swift-playground.playground")])
        #expect(app.studioViewSegments.last?.title == "Playground")
        #expect(!app.studioViews.contains(EditorStudioView("swift-playground")))
    }

    @Test("another plugin mounts a selectable right panel without adding a workbench panel")
    func foreignRegion() throws { try WorkbenchUITestSupport.withEnvironment { interactions, _ in
        let (app, directory) = try makeApp()
        defer { app.shutdown(); EditorAssistantSurface.release(app); try? FileManager.default.removeItem(at: directory) }
        let source = try #require(BundledPlugins.plugin(id: "studio.ai"))
        let owner = try PluginPackageLoader().load(at: source.package)
        let extensionURL = directory.appendingPathComponent("reports.coveplugin")
        try FileManager.default.copyItem(at: source.package, to: extensionURL)
        var manifest = owner.manifest
        manifest.id = "example.reports"
        manifest.contributes = ContributionDescriptor()
        manifest.requires = [.init(kind: .plugin, id: "studio.ai")]
        var region = PanelContribution(id: "example-reports", title: "Reports", slot: "trailing", content: .entryPoint("view"))
        region.inSurface = "studio.ai.assistant"
        try manifest.contributes.set(PanelContributionPoint.self, descriptors: [region])
        try JSONEncoder().encode(manifest).write(to: extensionURL.appendingPathComponent("plugin.json"))
        let contributed = try PluginPackageLoader().load(at: extensionURL)
        app.pluginSession.editor.workbench.replace(WorkbenchCatalog(packages: [owner, contributed]))
        let surface = EditorAssistantSurface.of(app)
        surface.show(EditorStudioView("studio.ai.assistant"))
        if !surface.regions.trailing { surface.toggleRegion(leading: false) }
        let registry = EditorRootViewFactory.makeRegistry(app: app)
        #expect(registry.descriptor(for: "example-reports") == nil)
        let controller = WorkspaceController(document: EditorWorkspaceDefaults.makeDocument(registry: registry))
        let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
        graph.install(root: EditorRootView(app: app, controller: controller, registry: registry))
        func settle() { for _ in 0..<3 { graph.recomposer.commitAll() }; graph.computeLayout(width: 1280, height: 800) }
        settle()
        try WorkbenchUITestSupport.activate("plugin-region-tab-example-reports", in: graph.tree.root, registry: interactions)
        settle()
        #expect(graph.layoutSnapshot().contains { $0.debugName == "plugin-region-content-example-reports" })
        app.pluginSession.editor.workbench.replace(WorkbenchCatalog(packages: [owner]))
        settle()
        #expect(!graph.layoutSnapshot().contains { $0.debugName == "plugin-region-content-example-reports" })
    } }

    @Test("clearing the conversation clears the review it proposed")
    func clearingConversationDropsReview() throws {
        let (app, directory) = try makeApp()
        defer {
            app.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        app.store.dispatch(.setPendingConfirmationRequest(
            ConfirmationRequestBatch(batchID: "batch", origin: "test",
                                     correlationID: "correlation", questions: [])
        ))
        app.store.dispatch(.appendChatMessage(AIChatMessage(role: .user, text: "hi")))
        #expect(app.store.pendingConfirmationRequest != nil)

        app.store.dispatch(.clearChatHistory)

        #expect(app.store.chatMessages.isEmpty)
        // A review is an assistant-authored plan, and it is persisted: leaving
        // it behind would restore a review for a conversation that is gone.
        #expect(app.store.pendingConfirmationRequest == nil)
    }
}
