import Foundation
import PluginRuntime
import Testing
@testable import EditorCore

@Suite("Workbench contributions", .serialized)
@MainActor
struct WorkbenchContributionsTests {
    @Test func viewPanelNeedsNoRuntimeAndFollowsItsPackage() async throws {
        let root = try package(id: "fixture.chat", panels: #"[{"id": "fixture-chat", "title": "Chat", "view": "agent"}]"#)
        let project = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: project) }
        let app = try EditorApplication(projectDirectory: project.path, seedPreviewScene: false,
                                        trustedPluginHostExecutableURL: nil)
        defer { app.shutdown() }
        var changes = 0
        app.setWorkbenchChangeHandler { changes += 1 }

        _ = try await app.enablePlugin(at: root, authorization: try authorize(root, in: app))
        #expect(app.pluginSession.hosts.pluginIDs.isEmpty)
        #expect(app.workbenchCatalog.panel(view: .agent)?.id == "fixture-chat")
        #expect(app.workbenchCatalog.panel(id: "fixture-chat")?.slot == "trailing")
        #expect(app.agentPanelID == nil)
        #expect(changes == 1)
        let enabled = try #require(app.store.pluginManagement.installed.first { $0.id == "fixture.chat" })
        #expect(enabled.categories == [.ui])

        try await app.disablePlugin(id: "fixture.chat")
        #expect(app.workbenchCatalog.panels.isEmpty)
        #expect(changes == 2)
    }

    @Test func panelsCannotTakeHostIdentifiersUnknownViewsOrAnotherPackagesPanel() async throws {
        let project = try directory()
        let first = try package(id: "fixture.first", panels: #"[{"id": "shared", "title": "Shared", "view": "agent"}]"#)
        let second = try package(id: "fixture.second", panels: #"[{"id": "shared", "title": "Shared", "view": "agent"}]"#)
        let builtIn = try package(id: "fixture.console", panels: #"[{"id": "console", "title": "Console", "view": "agent"}]"#)
        let unknown = try package(id: "fixture.browser", panels: #"[{"id": "browser", "title": "Browser", "view": "browser"}]"#)
        defer { for url in [project, first, second, builtIn, unknown] { try? FileManager.default.removeItem(at: url) } }
        let app = try EditorApplication(projectDirectory: project.path, seedPreviewScene: false,
                                        trustedPluginHostExecutableURL: nil)
        defer { app.shutdown() }

        _ = try await app.enablePlugin(at: first, authorization: try authorize(first, in: app))
        for rejected in [second, builtIn, unknown] {
            await #expect(throws: PluginManifestValidationError.invalidContribution(PanelContributionPoint.id)) {
                _ = try await app.enablePlugin(at: rejected, authorization: try authorize(rejected, in: app))
            }
        }
        #expect(app.workbenchCatalog.panels.map(\.pluginID) == ["fixture.first"])
    }

    @Test func commandsAreQualifiedByPackageAndPanelsSeeOnlyTheirOwn() throws {
        let one = try catalogPackage(id: "fixture.one", commands: ["refresh", "open"])
        let two = try catalogPackage(id: "fixture.two", commands: ["refresh"])
        let catalog = WorkbenchCatalog(packages: [two, one])
        #expect(catalog.commands.map(\.id) == ["fixture.one.refresh", "fixture.one.open", "fixture.two.refresh"])
        #expect(catalog.command(pluginID: "fixture.two", name: "refresh")?.title == "Refresh")
        #expect(catalog.command(pluginID: "fixture.two", name: "open") == nil)
        #expect(catalog.commandIDs(pluginID: "fixture.one") == ["refresh", "open"])
        #expect(catalog.commands.first { $0.name == "open" }?.showsInPalette == false)
    }

    @Test func panelStateKeepsContentWhileReloadingAndReportsFailures() async throws {
        let panel = try #require(ContributedPanel(pluginID: "fixture.status",
            contribution: PanelContribution(id: "status", title: "Status", content: .entryPoint("panel"))))
        var replies: [Result<PanelModel, Error>] = [
            .success(PanelModel(sections: [.init(items: [.init(title: "Clean")])])),
            .failure(PluginWorkbenchResultError.invalidPanel),
        ]
        let state = PluginPanelState(source: .panel(panel)) { try replies.removeFirst().get() }
        state.refresh()
        #expect(state.snapshot.isLoading)
        await settle(state)
        #expect(state.snapshot.model?.sections.first?.items.first?.title == "Clean")

        state.refresh()
        #expect(state.snapshot.isLoading)
        #expect(state.snapshot.model != nil)
        await settle(state)
        #expect(state.snapshot.model != nil)
        #expect(state.snapshot.failure == PluginWorkbenchResultError.invalidPanel.errorDescription)
    }

    @Test func aCommandRefreshesOnlyItsPackagesPanels() async throws {
        let session = WorkbenchSession()
        func panel(_ plugin: String, _ id: String) throws -> ContributedPanel {
            try #require(ContributedPanel(pluginID: plugin,
                contribution: PanelContribution(id: id, title: id, content: .entryPoint("panel"))))
        }
        var calls: [String: Int] = [:]
        let mine = session.state(for: .panel(try panel("fixture.mine", "mine"))) { calls["mine", default: 0] += 1; return PanelModel() }
        let other = session.state(for: .panel(try panel("fixture.other", "other"))) { calls["other", default: 0] += 1; return PanelModel() }
        await settle(mine)
        await settle(other)
        #expect(calls == ["mine": 1, "other": 1])

        session.refreshContent(of: "fixture.mine")
        await settle(mine)
        #expect(calls == ["mine": 2, "other": 1])
    }

    // MARK: Fixtures

    private func settle(_ state: PluginPanelState) async {
        for _ in 0..<100 where state.snapshot.isLoading { await Task.yield() }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func package(id: String, panels: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).guavaplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("""
        {"id":"\(id)","version":1,"name":"\(id)","description":"Fixture",
         "access":"read","imports":[],"composable_host_capabilities":[],
         "contributes":{"guava.ui.panel/v1":\(panels)}}
        """.utf8).write(to: root.appendingPathComponent("plugin.json"))
        return root
    }

    private func authorize(_ root: URL, in app: EditorApplication) throws -> PluginAuthorizationRecord {
        try app.makePluginAuthorization(afterUserApprovalOf: try app.inspectPlugin(at: root))
    }

    /// Commands need a runtime to load, so catalog tests attach them to a loaded package's manifest.
    private func catalogPackage(id: String, commands: [String]) throws -> ValidatedPluginPackage {
        let root = try package(id: id, panels: "[]")
        defer { try? FileManager.default.removeItem(at: root) }
        var package = try PluginPackageLoader().load(at: root)
        try package.manifest.contributes.set(CommandContributionPoint.self, descriptors: commands.map {
            CommandContribution(id: $0, title: $0.capitalized, entryPoint: "command", palette: $0 == "open" ? false : nil)
        })
        return package
    }
}
