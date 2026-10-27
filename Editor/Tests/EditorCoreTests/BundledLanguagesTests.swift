import Foundation
import PluginRuntime
import Testing
@testable import EditorCore

@Suite("Bundled Text Languages")
struct BundledLanguagesTests {
    @Test @MainActor func formattingActivatesOnDemandWithoutResettingChat() async throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let app = try EditorApplication(projectDirectory: project.path)
        defer { app.shutdown() }
        let plugin = try #require(app.bundledPlugins.first { $0.id == "studio.languages" })
        await app.setBundledPlugin(plugin, enabled: true)
        #expect(app.pluginSession.manager.activeBindings[plugin.id] == nil)
        app.store.dispatch(.appendChatMessage(AIChatMessage(role: .user, text: "Keep this conversation")))
        let chat = app.store.state.assistant.chatMessages
        try await app.activatePlugins(event: "onAIChat")
        #expect(app.pluginSession.manager.activeBindings[plugin.id] == nil)
        #expect(try await app.formatDocument(languageID: "latex", text: "first  \n") == "first\n")
        #expect(app.pluginSession.manager.activeBindings[plugin.id] != nil)
        #expect(app.store.state.assistant.chatMessages == chat)
        let verb = plugin.id + ".format"
        #expect(app.pluginCapabilityExecutor?.registry.descriptor(for: verb)?.isAIExposed == false)
        try await app.disablePlugin(id: plugin.id)
        #expect(try await app.formatDocument(languageID: "latex", text: "first  \n") == nil)
        #expect(app.store.state.assistant.chatMessages == chat)
    }

    @Test func latexFormatCapabilityFormatsWholeDocument() throws {
        let url = try #require(BundledPlugins.plugin(id: "studio.languages")?.package)
        let package = try PluginPackageLoader().load(at: url)
        let format = try #require(((try? package.manifest.contributes.decode(LanguageContributionPoint.self)) ?? []).first { $0.id == "latex" }?.format)
        #expect(format.entryPoint == "format")
        let runtime = BunPluginRuntime(processes: PluginProcessService(), http: PluginHTTPService())
        let output = try runtime.prepare(
            package,
            capabilityID: package.manifest.id + "." + format.entryPoint,
            input: try JSONEncoder().encode(["text": "first  \r\n\r\n\r\nsecond\t\n"]),
            querySnapshot: nil,
            limits: .secureDefault
        )
        #expect(try JSONDecoder().decode(String.self, from: output)
            == "first\n\nsecond\n")
    }

    @Test func languageGrammarAndOutlineAreDeclaredByThePackage() throws {
        let url = try #require(BundledPlugins.plugin(id: "studio.languages")?.package)
        let package = try PluginPackageLoader().load(at: url)
        let latex = try #require(((try? package.manifest.contributes.decode(LanguageContributionPoint.self)) ?? []).first { $0.id == "latex" })
        #expect(latex.grammar?.rules.isEmpty == false)
        #expect(latex.outline?.rules.isEmpty == false)
        #expect(latex.format?.entryPoint == "format")
    }
}
