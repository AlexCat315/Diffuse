import PluginRuntime
@testable import EditorUI
@testable import EditorCore
import Foundation
import CoveUI
import CoveUICompose
import CoveUIRuntime
import CoveUIWorkspace
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

    @Test("The host draws every component of a plugin view and sends its actions back")
    func viewRendersAndRaisesActions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-panel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: false)
        defer { app.shutdown() }
        try install(in: app)
        let panel = try #require(app.workbenchCatalog.panel(id: "fixture-status"))
        var events: [UIEvent] = []
        let tree = try JSONDecoder().decode(UINode.self, from: Data("""
            {"type": "column", "spacing": 8, "padding": 10, "children": [
              {"type": "row", "align": "center", "children": [
                {"type": "textField", "id": "draft", "placeholder": "New item", "submit": "add", "flex": 1},
                {"type": "button", "title": "Add", "style": "primary", "action": "add"}]},
              {"type": "section", "title": "Items", "children": [
                {"type": "row", "children": [
                  {"type": "toggle", "id": "done", "value": false, "action": "toggle"},
                  {"type": "text", "text": "Ship", "style": "strong"},
                  {"type": "badge", "text": "new", "tone": "accent"},
                  {"type": "button", "icon": "stop", "action": "remove", "arguments": {"index": 0}}]}]},
              {"type": "select", "id": "filter", "value": "all", "options": [{"value": "all", "label": "All"}, {"value": "done", "label": "Done"}]},
              {"type": "disclosure", "title": "Details", "expanded": true, "action": "expand", "children": [
                {"type": "table", "columns": ["Name", "Size"], "rows": [{"cells": ["a", "1"], "action": "pick"}, {"cells": ["b", "2"]}]}]},
              {"type": "progress", "percent": 40}, {"type": "icon", "name": "play"}, {"type": "spacer"}]}
            """.utf8))
        let session = app.pluginSession.workbench.session(for: .panel(panel), invoke: { _, event in
            if let event { events.append(event) }
            return PluginViewResult(state: .object([:]), ui: tree)
        }, effects: { _ in })
        for _ in 0..<100 where session.snapshot.isBusy { await Task.yield() }
        #expect(app.viewSession(for: panel) === session)

        try WorkbenchUITestSupport.withEnvironment { interactions, _ in
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: PluginView(session: session).theme(EditorVisualTheme.make(dark: true)))
            for _ in 0..<3 { graph.recomposer.commitAll(); graph.computeLayout(width: 360, height: 600) }
            let names = Set(graph.layoutSnapshot().map(\.debugName))
            for name in ["plugin-panel-fixture-status", "plugin-field-draft", "plugin-button-add", "plugin-toggle-done",
                         "plugin-button-remove", "plugin-select-filter", "plugin-disclosure-expand"] {
                #expect(names.contains(name), "\(name) is not drawn")
            }
            #expect(graph.layoutSnapshot().filter { $0.debugName == "plugin-row" }.count == 2)
            session.setValue(.string("Ship"), for: "draft")
            try WorkbenchUITestSupport.activate("plugin-button-remove", in: graph.tree.root, registry: interactions)
        }
        for _ in 0..<100 where session.snapshot.isBusy || events.isEmpty { await Task.yield() }
        #expect(events.first?.action == "remove")
        #expect(events.first?.arguments == .object(["index": .number(0)]))
        #expect(events.first?.values["draft"] == .string("Ship"))
    }

    @Test("A document view gets the document's path and current text")
    func documentViewRenders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-document-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try EditorApplication(projectDirectory: directory.path, seedPreviewScene: false)
        defer { app.shutdown() }
        try install(in: app)
        let view = try #require(app.workbenchCatalog.documentViews(forPath: "data.csv").first)
        let session = app.pluginSession.workbench.session(for: .document(view, path: "data.csv"), invoke: { _, _ in
            PluginViewResult(ui: try JSONDecoder().decode(UINode.self, from: Data("""
                {"type": "table", "columns": ["a"], "rows": [{"cells": ["1"]}, {"cells": ["2"]}, {"cells": ["3"]}]}
                """.utf8)))
        }, effects: { _ in })
        for _ in 0..<100 where session.snapshot.isBusy { await Task.yield() }
        #expect(app.viewSession(for: view, path: "data.csv") === session)
        try WorkbenchUITestSupport.withEnvironment { _, _ in
            let graph = ViewGraph(tree: NodeTree(), recomposer: Recomposer())
            graph.install(root: PluginView(session: session).theme(EditorVisualTheme.make(dark: true)))
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).coveplugin")
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
