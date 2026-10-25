import PluginRuntime
@testable import EditorUI
@testable import EditorCore
import Foundation
import GuavaUI
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIWorkspace
import Testing

@Suite("Plugin commands and panels", .serialized)
@MainActor
struct PluginPanelTests {
    @Test("Package commands reach the palette, described panels reach the Window menu")
    func commandCatalog() throws {
        try withApp { app in
            let catalog = EditorCommandCatalog.make(EditorCommandContext(app: app))
            let refresh = try #require(catalog.entries.first { $0.id == "plugin.fixture.tools.refresh" })
            // A command a menu holds appears once: in the menu, which feeds the palette.
            #expect(catalog.entries.filter { $0.id == refresh.id }.count == 1)
            let run = try #require(catalog.menus.first { $0.id == "run" })
            #expect(run.items.contains { if case let .entry(entry) = $0 { entry.id == refresh.id } else { false } })
            #expect(app.workbenchCatalog.toolbarItems.map(\.command.id) == ["fixture.tools.refresh"])
            #expect(app.workbenchCatalog.documentViews(forPath: "Data/report.CSV").map(\.id) == ["table"])
            #expect(app.workbenchCatalog.documentViews(forPath: "notes.md").isEmpty)
            guard case let .plugin(pluginID, name) = refresh.command else { Issue.record("not a plugin command"); return }
            #expect(pluginID == "fixture.tools" && name == "refresh")
            #expect(refresh.inPalette)
            #expect(catalog.entries.first { $0.id == "plugin.fixture.tools.open" }?.inPalette == false)
            let window = try #require(catalog.menus.first { $0.id == "window" })
            #expect(window.items.contains { if case let .entry(entry) = $0 { entry.id == "panel.fixture-status" } else { false } })
            #expect(!catalog.entries.contains { $0.id == "agent.show" })
        }
    }

    @Test("Described panels join and leave the registry with their package")
    func registryFollowsCatalog() throws {
        try withApp { app in
            let registry = EditorRootViewFactory.makeRegistry(app: app)
            #expect(registry.descriptor(for: "fixture-status")?.defaultSlot == .leading)
            #expect(registry.descriptor(for: "fixture-status")?.panel.title == "Status")

            app.pluginSession.workbench.replace(.empty)
            EditorRootViewFactory.syncContributedPanels(app: app, registry: registry)
            #expect(registry.descriptor(for: "fixture-status") == nil)
            #expect(registry.descriptor(for: "console") != nil)
        }
    }

    @Test("The host draws a described panel's actions and rows")
    func modelPanelRenders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-panel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: false)
        defer { app.shutdown() }
        try install(in: app)
        let panel = try #require(app.workbenchCatalog.panel(id: "fixture-status"))
        let state = app.pluginSession.workbench.state(for: .panel(panel)) {
            PanelModel(sections: [.init(title: "Changes", items: [.init(title: "README.md", badge: "M", command: "open"),
                                                                  .init(title: "Package.swift", tone: .muted)])],
                       actions: [.init(title: "Refresh", command: "refresh")])
        }
        for _ in 0..<100 where state.snapshot.isLoading { await Task.yield() }
        #expect(app.panelState(for: panel) === state)

        try WorkbenchUITestSupport.withEnvironment { _, _ in
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: PluginModelPanel(app: app, state: state).theme(EditorVisualTheme.make(dark: true)))
            for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 320, height: 400) }
            let frames = graph.layoutSnapshot()
            #expect(frames.contains { $0.debugName == "plugin-panel-fixture-status" })
            #expect(frames.contains { $0.debugName == "plugin-action-refresh" })
            #expect(frames.filter { $0.debugName == "plugin-row" }.count == 2)
        }
    }

    @Test("A document view draws the package's description of the document")
    func documentViewRenders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-document-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: false)
        defer { app.shutdown() }
        try install(in: app)
        let view = try #require(app.workbenchCatalog.documentViews(forPath: "data.csv").first)
        let state = app.pluginSession.workbench.state(for: .document(view, path: "data.csv")) {
            PanelModel(sections: [.init(items: [.init(title: "a"), .init(title: "b"), .init(title: "c")])])
        }
        for _ in 0..<100 where state.snapshot.isLoading { await Task.yield() }
        #expect(app.documentViewState(for: view, path: "data.csv") === state)
        try WorkbenchUITestSupport.withEnvironment { _, _ in
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: PluginModelPanel(app: app, state: state).theme(EditorVisualTheme.make(dark: true)))
            for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 320, height: 400) }
            let frames = graph.layoutSnapshot()
            #expect(frames.contains { $0.debugName == "plugin-document-table" })
            #expect(frames.filter { $0.debugName == "plugin-row" }.count == 3)
        }
    }

    // MARK: Fixtures

    private func withApp(_ work: (EditorApplication) throws -> Void) throws {
        try WorkbenchUITestSupport.withEnvironment { _, _ in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-panel-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: false)
            defer { app.shutdown() }
            try install(in: app)
            try work(app)
        }
    }

    /// Commands and described panels need a runtime to load, so the fixture
    /// attaches them to a declarative package's manifest.
    private func install(in app: EditorApplication) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).guavaplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("""
        {"id":"fixture.tools","version":1,"name":"Tools","description":"Fixture",
         "access":"read","imports":[],"composable_host_capabilities":[]}
        """.utf8).write(to: root.appendingPathComponent("plugin.json"))
        var package = try PluginPackageLoader().load(at: root)
        try package.manifest.contributes.set(CommandContributionPoint.self, descriptors: [
            CommandContribution(id: "refresh", title: "Refresh Tools", entryPoint: "command"),
            CommandContribution(id: "open", title: "Open", entryPoint: "command", palette: false),
        ])
        try package.manifest.contributes.set(PanelContributionPoint.self, descriptors: [
            PanelContribution(id: "fixture-status", title: "Status", slot: "leading", content: .entryPoint("panel")),
        ])
        try package.manifest.contributes.set(MenuContributionPoint.self, descriptors: [
            MenuContribution(command: "refresh", menu: "run"),
        ])
        try package.manifest.contributes.set(ToolbarContributionPoint.self, descriptors: [
            ToolbarContribution(command: "refresh", icon: "toolbar-arrow-path"),
        ])
        try package.manifest.contributes.set(DocumentViewContributionPoint.self, descriptors: [
            DocumentViewContribution(id: "table", title: "Table", extensions: ["csv"], entryPoint: "document"),
        ])
        app.pluginSession.workbench.replace(WorkbenchCatalog(packages: [package]))
    }
}
