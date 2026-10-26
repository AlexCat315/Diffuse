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

    @Test func aViewHandsBackItsStateAndTheControlValuesWithEachEvent() async throws {
        var calls: [(state: PluginJSON?, event: UIEvent?)] = []
        let session = PluginViewSession(source: .panel(try statusPanel())) { state, event in
            calls.append((state, event))
            var count = 0
            if case let .object(object)? = state, case let .number(saved)? = object["count"] { count = Int(saved) }
            if event?.action == "add" { count += 1 }
            return PluginViewResult(state: .object(["count": .number(Double(count))]), ui: Self.form(count: count, draft: event == nil ? nil : ""))
        }
        session.render()
        #expect(session.snapshot.isBusy)
        await settle(session)
        #expect(calls.first?.state == nil && calls.first?.event == nil)
        #expect(session.values == ["draft": .string(""), "done": .bool(false)])

        session.setValue(.string("Ship"), for: "draft")
        session.setValue(.bool(true), for: "done")
        session.send(action: "add")
        await settle(session)
        #expect(calls.count == 2)
        #expect(calls[1].state == .object(["count": .number(0)]))
        #expect(calls[1].event?.values == ["draft": .string("Ship"), "done": .bool(true)])
        // After the event the plugin's answers win: it cleared the field and kept the toggle off.
        #expect(session.values == ["draft": .string(""), "done": .bool(false)])

        session.setValue(.string("Next"), for: "draft")
        session.render()
        await settle(session)
        // A plain render keeps what the user typed.
        #expect(session.values["draft"] == .string("Next"))
        #expect(calls[2].state == .object(["count": .number(1)]))
    }

    @Test func eventsRunInOrderAndAFailureKeepsTheLastTree() async throws {
        var order: [String] = []
        var fail = false
        let session = PluginViewSession(source: .panel(try statusPanel())) { _, event in
            order.append(event?.action ?? "render")
            await Task.yield()
            if fail { throw PluginWorkbenchResultError.invalidView }
            return PluginViewResult(ui: Self.form(count: order.count, draft: nil))
        }
        session.render()
        session.send(action: "first")
        session.send(action: "second")
        await settle(session)
        #expect(order == ["render", "first", "second"])
        let tree = session.snapshot.ui
        fail = true
        session.send(action: "third")
        await settle(session)
        #expect(session.snapshot.ui == tree)
        #expect(session.snapshot.failure == PluginWorkbenchResultError.invalidView.errorDescription)
    }

    @Test func typingReachesThePluginOnlyThroughADebouncedChange() async throws {
        var events: [UIEvent] = []
        let session = PluginViewSession(source: .panel(try statusPanel())) { _, event in
            if let event { events.append(event) }
            return PluginViewResult(ui: Self.form(count: 0, draft: nil))
        }
        session.render()
        await settle(session)
        session.setValue(.string("a"), for: "draft")
        session.setValue(.string("ab"), for: "draft", change: "search")
        session.setValue(.string("abc"), for: "draft", change: "search")
        try await Task.sleep(for: .milliseconds(450))
        await settle(session)
        #expect(events.map(\.action) == ["search"])
        #expect(events.first?.value == .string("abc"))
    }

    @Test func aCommandRendersOnlyItsPackagesViews() async throws {
        let workbench = WorkbenchSession()
        func panel(_ plugin: String, _ id: String) throws -> ContributedPanel {
            try #require(ContributedPanel(pluginID: plugin,
                contribution: PanelContribution(id: id, title: id, content: .entryPoint("view"))))
        }
        var calls: [String: Int] = [:]
        let mine = workbench.session(for: .panel(try panel("fixture.mine", "mine")), invoke: { _, _ in
            calls["mine", default: 0] += 1; return PluginViewResult(ui: UINode(.spacer))
        }, effects: { _ in })
        let other = workbench.session(for: .panel(try panel("fixture.other", "other")), invoke: { _, _ in
            calls["other", default: 0] += 1; return PluginViewResult(ui: UINode(.spacer))
        }, effects: { _ in })
        await settle(mine)
        await settle(other)
        #expect(calls == ["mine": 1, "other": 1])
        workbench.renderViews(of: "fixture.mine")
        await settle(mine)
        #expect(calls == ["mine": 2, "other": 1])
    }

    @Test func effectsOpenFilesShowPanelsAndNotify() async throws {
        let project = try directory()
        defer { try? FileManager.default.removeItem(at: project) }
        try Data("todo".utf8).write(to: project.appendingPathComponent("todo.md"))
        let app = try EditorApplication(projectDirectory: project.path, seedPreviewScene: false,
                                        trustedPluginHostExecutableURL: nil)
        defer { app.shutdown() }
        var notes: [String] = []
        var panels: [String] = []
        app.setPluginNotificationHandler { text, isError in notes.append((isError ? "!" : "") + text) }
        app.setActivatePanelHandler { panels.append($0) }
        app.applyPluginEffects([.message("Saved"), .error("Broken"), .panel("checklist"), .open(path: "todo.md")])
        #expect(notes == ["Saved", "!Broken"])
        #expect(panels == ["checklist", "documents"])
        #expect(app.workstation.documents.snapshot.selected?.path == "todo.md")
    }

    // MARK: Fixtures

    private func settle(_ session: PluginViewSession) async {
        for _ in 0..<200 where session.snapshot.isBusy { await Task.yield() }
    }

    private func statusPanel() throws -> ContributedPanel {
        try #require(ContributedPanel(pluginID: "fixture.status",
            contribution: PanelContribution(id: "status", title: "Status", content: .entryPoint("view"))))
    }

    private static func form(count: Int, draft: String?) -> UINode {
        let value = draft.map { #", "value": "\#($0)""# } ?? ""
        return try! JSONDecoder().decode(UINode.self, from: Data("""
            {"type": "column", "children": [
              {"type": "textField", "id": "draft", "submit": "add"\(value)},
              {"type": "toggle", "id": "done", "value": false},
              {"type": "text", "text": "\(count)"}]}
            """.utf8))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func package(id: String, panels: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).coveplugin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("""
        {"id":"\(id)","version":1,"name":"\(id)","description":"Fixture",
         "access":"read","imports":[],"composable_host_capabilities":[],
         "contributes":{"cove.ui.panel/v1":\(panels)}}
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
