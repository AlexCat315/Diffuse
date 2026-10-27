public import Foundation
public import PluginRuntime
public import Testing
@testable public import EditorCore

@Suite("Bun editor workflow", .serialized)
@MainActor
struct EditorBunWorkflowTests {
    @Test("explicit installations survive restarts, retain disabled state and reject changed code")
    func installationPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(BundledPlugins.plugin(id: "studio.ai"))
        let package = root.appendingPathComponent("external.coveplugin")
        try FileManager.default.copyItem(at: source.package, to: package)
        var manifest = try PluginPackageLoader().load(at: package).manifest
        manifest.id = "test.persistence-" + UUID().uuidString.lowercased()
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("plugin.json"))
        let host = try #require(EditorPluginHostLocator.resolve())
        let installations = PluginInstallations(root: root.appendingPathComponent("installed"))
        func application(_ name: String) throws -> EditorApplication {
            let project = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let app = try EditorApplication(projectDirectory: project.path, trustedPluginHostExecutableURL: host)
            app.pluginSession.editor.installations = installations
            return app
        }
        let first = try application("first")
        await first.inspectPluginForManagement(at: package)
        await first.authorizeAndEnableInspectedPlugin()
        #expect(first.enabledPluginManifests[manifest.id] != nil)
        let record = try #require(installations.records().first)
        #expect(record.enabled)
        #expect(first.pluginSession.manager.packageURLs[manifest.id] == installations.package(for: record))
        first.shutdown()
        // The original development directory can go away after installation.
        try FileManager.default.removeItem(at: package)
        let second = try application("second")
        await second.restoreInstalledPlugins()
        #expect(second.enabledPluginManifests[manifest.id] != nil)
        try await second.disablePlugin(id: manifest.id)
        second.shutdown()
        let third = try application("third")
        await third.restoreInstalledPlugins()
        #expect(third.enabledPluginManifests[manifest.id] == nil)
        #expect(third.pluginSession.manager.packageURLs[manifest.id] != nil)
        await third.setInstalledPlugin(id: manifest.id, enabled: true)
        #expect(third.enabledPluginManifests[manifest.id] != nil)
        third.shutdown()
        let code = installations.package(for: record).appendingPathComponent("plugin.js")
        var bytes = try Data(contentsOf: code); bytes.append(Data("\n// changed".utf8)); try bytes.write(to: code)
        let fourth = try application("fourth")
        defer { fourth.shutdown() }
        await fourth.restoreInstalledPlugins()
        #expect(fourth.enabledPluginManifests[manifest.id] == nil)
        #expect(fourth.pluginSession.hosts.existing(manifest.id) == nil)
        #expect(fourth.store.state.assistant.pluginManagement.phase == .failed)
    }

    @Test("third-party AI surfaces, services and jobs are withdrawn across loaded projects")
    func withdrawal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstPath = root.appendingPathComponent("first"), secondPath = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(BundledPlugins.plugin(id: "studio.ai"))
        let package = root.appendingPathComponent("external.coveplugin")
        try FileManager.default.copyItem(at: source.package, to: package)
        let id = "test.ai-" + UUID().uuidString.lowercased()
        var manifest = try PluginPackageLoader().load(at: package).manifest
        manifest.id = id
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("plugin.json"))
        let host = try #require(EditorPluginHostLocator.resolve())
        let first = try EditorApplication(projectDirectory: firstPath.path, trustedPluginHostExecutableURL: host)
        let second = try EditorApplication(projectDirectory: secondPath.path, trustedPluginHostExecutableURL: host)
        defer { first.shutdown(); second.shutdown() }
        for app in [first, second] {
            let inspection = try app.inspectPlugin(at: package)
            try await app.enablePlugin(at: package, authorization: PluginAuthorizationRecord(inspection: inspection))
            try await app.activatePlugins(event: "onStartup")
            app.setPluginPeers { [weak first, weak second] in [first, second].compactMap { $0 } }
        }
        let context = String(decoding: try JSONSerialization.data(withJSONObject: ["storage": root.appendingPathComponent("storage").path, "workspace": "", "projects": []]), as: UTF8.self)
        let payload = try await first.readEntryPoint(pluginID: id, entryPoint: "view", event: "onView:assistant",
            input: ["view": "assistant", "state": "", "event": "", "context": context])
        #expect(try PluginViewResult(json: payload, panels: ["assistant"]).refreshAfterMilliseconds == 500)
        #expect(first.workbenchCatalog.panels.first?.surface == "assistant")
        let job = try first.pluginSession.editor.jobs.start(owner: id) {
            try await Task.sleep(for: .seconds(30)); return Data("null".utf8)
        }
        try await first.disablePlugin(id: id)
        for app in [first, second] {
            #expect(app.workbenchCatalog.panels.isEmpty)
            #expect(app.pluginSession.hosts.existing(id) == nil)
            #expect(app.pluginSession.contributions.services.snapshot.values.isEmpty)
            #expect(app.pluginSession.contributions.extensionPoints.snapshot.values.isEmpty)
        }
        #expect(throws: (any Error).self) { try first.pluginSession.editor.jobs.poll(id: job, owner: id) }
    }
}
