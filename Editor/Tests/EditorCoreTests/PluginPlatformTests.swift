import Foundation
import GuavaUICompose
import GuavaUIRuntime
import PluginRuntime
import Testing
@testable import EditorCore

@Suite("Plugin platform", .serialized)
@MainActor
struct PluginPlatformTests {
    @Test func declarativePackageBindsResourcesAndManifest() throws {
        let root = try package()
        defer { try? FileManager.default.removeItem(at: root) }
        let loaded = try PluginPackageLoader().load(at: root)
        #expect(loaded.runtime == nil)
        #expect(throws: PluginPackageError.runtimeRequired) { try loaded.requireRuntime() }
        let inspection = PluginInspection(package: loaded, contracts: [])
        let authorization = try PluginAuthorizationRecord(inspection: inspection)
        #expect(authorization.isStillValid(for: inspection))
        #expect(inspection.resourceHashes["resources/theme.json"]?.count == 64)
        #expect(try JSONDecoder().decode(PluginAuthorizationRecord.self,
                                        from: JSONEncoder().encode(authorization)) == authorization)

        try Data(##"{"version":1,"dark":{"colors":{"accent":"#00ff00"}}}"##.utf8)
            .write(to: root.appendingPathComponent("resources/theme.json"))
        #expect(throws: PluginAuthorizationError.noLongerValid) {
            try loaded.resource(at: "resources/theme.json")
        }
        let changed = try PluginPackageLoader().load(at: root)
        #expect(!authorization.isStillValid(for: PluginInspection(package: changed, contracts: [])))
        var changedManifest = inspection
        changedManifest.manifest.description = "Changed declaration"
        #expect(!authorization.isStillValid(for: changedManifest))
        #expect(authorization.authorityDigest
            != (try PluginAuthorizationRecord(inspection: changedManifest)).authorityDigest)
    }

    @Test func pathsLinksAndIncompleteRuntimeAreRejected() throws {
        let root = try package()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("resources/theme.json")
        let saved = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file,
            withDestinationURL: root.appendingPathComponent("plugin.json"))
        #expect(throws: PluginPackageError.symbolicLinkNotAllowed("resources/theme.json")) {
            try PluginPackageLoader().load(at: root)
        }
        try FileManager.default.removeItem(at: file)
        try saved.write(to: file)
        try Data().write(to: root.appendingPathComponent("capabilities.wit"))
        #expect(throws: PluginPackageError.incompleteRuntime) { try PluginPackageLoader().load(at: root) }
        for path in ["../theme.json", "resources/../theme.json", "/resources/theme.json",
                     "resources//theme.json", "resources\\theme.json"] {
            #expect(!PluginResource.isValidPath(path))
        }
    }

    @Test func contributionsRejectUnknownVersionsAndDuplicateIdentifiers() throws {
        let root = try package()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent("plugin.json")
        let original = try String(contentsOf: manifestURL, encoding: .utf8)
        try Data(original.replacingOccurrences(of: "guava.theme/v1", with: "guava.theme/v2").utf8)
            .write(to: manifestURL)
        #expect(throws: PluginManifestValidationError.invalidContribution("guava.theme/v2")) {
            try PluginPackageLoader().load(at: root)
        }
        var object = try #require(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        let descriptor: [String: String] = ["id": "test.theme", "title": "Test", "appearance": "dark",
                                           "path": "resources/theme.json"]
        object["contributes"] = ["guava.theme/v1": [descriptor, descriptor]]
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        #expect(throws: PluginManifestValidationError.invalidContribution("guava.theme/v1")) {
            try PluginPackageLoader().load(at: root)
        }
    }

    @Test func declarativeLifecycleNeedsNoHostAndDoesNotResetChat() async throws {
        let root = try package()
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: project)
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var manifest = try PluginPackageLoader().load(at: root).manifest
        try manifest.contributes.set(LanguageContributionPoint.self, descriptors: [
            LanguageContribution(id: "fixture", title: "Fixture", extensions: ["plgtest"],
                grammar: SyntaxGrammarContribution(rules: [SyntaxRuleContribution(pattern: "[0-9]+", token: "number")]))
        ])
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("plugin.json"))
        let app = try EditorApplication(projectDirectory: project.path, seedPreviewScene: false,
                                        trustedPluginHostExecutableURL: nil)
        defer { app.shutdown() }
        let inspection = try app.inspectPlugin(at: root)
        let authorization = try app.makePluginAuthorization(afterUserApprovalOf: inspection)
        app.store.dispatch(.appendChatMessage(AIChatMessage(role: .user, text: "Keep this conversation")))
        let chat = app.store.state.assistant.chatMessages
        app.store.dispatch(.setThemeID("test.theme"))
        let before = app.store.state.presentation.refreshRevision
        _ = try await app.enablePlugin(at: root, authorization: authorization)
        #expect(app.pluginSession.hosts.pluginIDs.isEmpty)
        #expect(app.pluginSession.manager.activeBindings.isEmpty)
        #expect(app.languageCatalog.descriptor(forExtension: "plgtest")?.id == "fixture")
        #expect(app.languageCatalog.syntaxRules(forLanguageID: "fixture").count == 1)
        #expect(app.enabledPluginInspections().contains { $0.manifest.id == "test.theme" })
        let enabled = try #require(app.store.pluginManagement.installed.first { $0.id == "test.theme" })
        #expect(enabled.categories == [.themes, .languages])
        #expect(enabled.lifecycle.phase == .enabled)
        #expect(app.resolvedTheme(dark: true).colors.accent
            == Color(red: 255, green: 0, blue: 0))
        app.store.dispatch(.setThemeID(EditorThemeCatalog.defaultThemeID))
        #expect(app.resolvedTheme(dark: true).colors.accent != Color(red: 255, green: 0, blue: 0))
        app.store.dispatch(.setThemeID("test.theme"))
        #expect(app.store.state.assistant.chatMessages == chat)
        try await app.reloadPlugin(id: "test.theme")
        #expect(app.store.state.assistant.chatMessages == chat)
        #expect(app.store.state.presentation.refreshRevision == before)
        try await app.disablePlugin(id: "test.theme")
        #expect(!app.themeCatalog.themes.contains { $0.id == "test.theme" })
        #expect(app.languageCatalog.descriptor(forExtension: "plgtest") == nil)
        #expect(app.pluginSession.hosts.pluginIDs.isEmpty)
        let disabled = try #require(app.store.pluginManagement.installed.first { $0.id == "test.theme" })
        #expect(!disabled.lifecycle.isEnabled)
        #expect(disabled.lifecycle.phase == .installed)
        await app.setInstalledPlugin(id: "test.theme", enabled: true)
        #expect(app.languageCatalog.descriptor(forExtension: "plgtest") != nil)
        try await app.uninstallPlugin(id: "test.theme")
        #expect(app.store.pluginManagement.installed.isEmpty)
    }

    @Test func themeResourceMutationRequiresReviewBeforeReload() async throws {
        let root = try package()
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: project)
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try EditorApplication(projectDirectory: project.path, seedPreviewScene: false)
        defer { app.shutdown() }
        app.store.dispatch(.setThemeID("test.theme"))
        let authorization = try PluginAuthorizationRecord(inspection: app.inspectPlugin(at: root))
        _ = try await app.enablePlugin(at: root, authorization: authorization)
        try Data(##"{"version":1,"dark":{"colors":{"accent":"#00ff00"}}}"##.utf8)
            .write(to: root.appendingPathComponent("resources/theme.json"))
        do {
            try await app.reloadPlugin(id: "test.theme")
            Issue.record("Changed resources must require reauthorization")
        } catch let error as EditorPluginCapabilityError {
            #expect(error == .pluginAuthorizationStale("test.theme"))
        }
        await app.reloadPluginFromManagement(id: "test.theme")
        #expect(app.store.state.assistant.pluginManagement.phase == .awaitingAuthorization)
        await app.authorizeAndEnableInspectedPlugin()
        #expect(app.resolvedTheme(dark: true).colors.accent
            == Color(red: 0, green: 255, blue: 0))
    }

    @Test func presentationPersistsThemeChoiceAndResetsRevisions() throws {
        var presentation = EditorPresentationState()
        presentation.setThemeID("test.theme")
        presentation.refreshThemeCatalog()
        presentation.forceRefresh()
        let saved = try JSONEncoder().encode(presentation)
        let restored = try JSONDecoder().decode(EditorPresentationState.self, from: saved)
        #expect(restored.themeID == "test.theme")
        #expect(restored.themeRevision == 0)
        #expect(restored.refreshRevision == 0)
    }

    @Test func themeDirectoriesAreIndependentBetweenEditorSessions() throws {
        let root = try package()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = EditorThemeCatalog()
        let second = EditorThemeCatalog()
        let registration = try first.register(PluginPackageLoader().load(at: root))
        #expect(first.snapshot.themes.contains { $0.id == "test.theme" })
        #expect(!second.snapshot.themes.contains { $0.id == "test.theme" })
        try registration.dispose()
        #expect(second.snapshot.themes.isEmpty)
    }

    @Test func providerSnapshotsBelongToTheirEditorSession() async throws {
        let root = try package()
        let firstProject = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let secondProject = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { for url in [root, firstProject, secondProject] { try? FileManager.default.removeItem(at: url) } }
        for url in [firstProject, secondProject] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var manifest = try PluginPackageLoader().load(at: root).manifest
        try manifest.contributes.set(AIProviderContributionPoint.self, descriptors: [
            AIProviderContribution(id: "fixture-provider", title: "Fixture", apiFormat: "openai-compatible",
                models: [AIModelContribution(id: "fixture", title: "Fixture")])
        ])
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("plugin.json"))
        let first = try EditorApplication(projectDirectory: firstProject.path)
        let second = try EditorApplication(projectDirectory: secondProject.path)
        defer { first.shutdown(); second.shutdown() }
        let inspection = try first.inspectPlugin(at: root)
        _ = try await first.enablePlugin(at: root, authorization: first.makePluginAuthorization(afterUserApprovalOf: inspection))
        #expect(first.aiProviderCatalog.provider(id: "fixture-provider") != nil)
        #expect(second.aiProviderCatalog.provider(id: "fixture-provider") == nil)
        try await first.disablePlugin(id: "test.theme")
        #expect(first.aiProviderCatalog.provider(id: "fixture-provider") == nil)
        #expect(second.aiProviderCatalog.providers.isEmpty)
    }

    private func package() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).guavaplugin")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("resources"),
                                                withIntermediateDirectories: true)
        try Data(##"{"version":1,"dark":{"colors":{"accent":"#ff0000"}}}"##.utf8)
            .write(to: root.appendingPathComponent("resources/theme.json"))
        let manifest = """
        {"id":"test.theme","version":1,"name":"Test theme","description":"Fixture",
         "access":"read","imports":[],"composable_host_capabilities":[],
         "resources":[{"id":"theme","path":"resources/theme.json","kind":"theme"}],
         "contributes":{"guava.theme/v1":[{"id":"test.theme","title":"Test theme",
            "appearance":"dark","path":"resources/theme.json"}]}}
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("plugin.json"))
        return root
    }
}


@Suite("Plugin host isolation")
struct PluginHostIsolationTests {
    @Test("each plugin gets its own host process")
    func perPluginProcesses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = PluginHostPool(executable: { root.appendingPathComponent("host") })
        let first = try pool.client(forPluginID: "fixture.one")
        let second = try pool.client(forPluginID: "fixture.two")
        #expect(first !== second)
        #expect(try pool.client(forPluginID: "fixture.one") === first)
        #expect(pool.pluginIDs == ["fixture.one", "fixture.two"])
    }

    @Test("dropping one plugin leaves the others running")
    func discardIsPerPlugin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = PluginHostPool(executable: { root.appendingPathComponent("host") })
        let kept = try pool.client(forPluginID: "fixture.kept")
        _ = try pool.client(forPluginID: "fixture.dropped")
        _ = pool.discard("fixture.dropped")
        #expect(pool.pluginIDs == ["fixture.kept"])
        #expect(try pool.client(forPluginID: "fixture.kept") === kept)
    }
}
