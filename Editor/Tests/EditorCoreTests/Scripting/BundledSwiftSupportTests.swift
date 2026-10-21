import Foundation
import Testing
import PluginRuntime
import PluginWasmtimeRuntime
import CapabilityRuntime
import LanguageServerRuntime
import ProcessRuntime
import GuavaUICompose
@testable import EditorCore

@Suite("Bundled Swift Support")
struct BundledSwiftSupportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GUAVA_TEST_REAL_SOURCEKIT"] == "1"), .timeLimit(.minutes(2)))
    func realSourceKitSemanticQueries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let file = DynamicScriptManager.ScriptFile(url: scripts.appendingPathComponent("Example.swift"))
        let source = "let greeting = \"hello\"\ngreeting.\n"
        try Data(source.utf8).write(to: file.url)
        let executable = try SourceKitLSPExecutableLocator.resolveExecutableURL()
        let client = PluginHostProcessClient(executableURL: try #require(EditorPluginHostLocator.resolve()))
        defer { client.stop() }
        let inspection = try client.inspectPlugin(at: BundledPlugins.swiftSupport)
        var context = PluginProcessContext(workspace: root)
        context.executables = ["sourcekit-lsp": executable]
        let binding = try client.loadPlugin(at: BundledPlugins.swiftSupport,
            authorization: PluginAuthorizationRecord(inspection: inspection), processContext: context)
        let adapter = PluginLanguageService()
        adapter.bind(binding, client: client)
        let support = ScriptLanguageSupport(scriptsDirectoryURL: scripts, engineModulePaths: [],
            executableURL: executable, connect: { try adapter.connect($0) })
        try await support.start(sources: [ScriptLanguageSource(file: file, text: TextBuffer(source))], onDiagnostics: { _ in })
        do {
            var completion = ScriptCompletionResult(items: [], isIncomplete: false)
            for _ in 0..<8 {
                completion = try await support.completion(scriptID: file.identifier, at: .init(line: 1, character: 9))
                if !completion.items.isEmpty { break }
                try await Task.sleep(for: .seconds(1))
            }
            #expect(completion.items.contains { $0.label.contains("uppercased") })
            let hover = try await support.hover(scriptID: file.identifier, at: .init(line: 0, character: 6))
            #expect(hover?.contents.contains("String") == true)
            await support.stop()
        } catch {
            await support.stop()
            throw error
        }
    }

    @Test func packagedLaunchUsesBuildProductsForScriptAnalysis() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let products = root.appendingPathComponent("products")
        for module in ["SceneRuntime", "ScriptRuntime"] {
            try FileManager.default.createDirectory(at: products.appendingPathComponent(module + ".swiftmodule"), withIntermediateDirectories: true)
        }
        let executable = root.appendingPathComponent("Editor.app/Contents/MacOS/EditorApp")
        let configuration = ProjectScriptBuildConfiguration.discover(for: executable,
            environment: ["GUAVA_BUILD_PRODUCTS_PATH": products.path])
        #expect(configuration.engineModulePaths == [products.path])
        let overridden = ProjectScriptBuildConfiguration.discover(for: executable,
            environment: ["GUAVA_BUILD_PRODUCTS_PATH": products.path, "GUAVA_ENGINE_MODULE_PATHS": "/SDK/Modules"])
        #expect(overridden.engineModulePaths == ["/SDK/Modules"])
    }

    @Test(.timeLimit(.minutes(1))) func isolatedLanguageServerRoundTripAndUnload() async throws {
        let fixture = try LSPProcessFixture()
        defer { fixture.remove() }
        let host = try #require(EditorPluginHostLocator.resolve())
        let client = PluginHostProcessClient(executableURL: host)
        defer { client.stop() }
        let url = fixture.root.appendingPathComponent("SwiftSupport.guavaplugin")
        try FileManager.default.copyItem(at: BundledPlugins.swiftSupport, to: url)
        var manifest = try JSONDecoder().decode(GuavaPluginManifest.self, from: Data(contentsOf: url.appendingPathComponent("plugin.json")))
        manifest.host.processes[0].environmentKeys += Array(fixture.environment.keys)
        try JSONEncoder().encode(manifest).write(to: url.appendingPathComponent("plugin.json"))
        let inspection = try client.inspectPlugin(at: url)
        let authorization = try PluginAuthorizationRecord(inspection: inspection)
        var context = PluginProcessContext(workspace: fixture.root)
        context.executables = ["sourcekit-lsp": fixture.executable]
        let binding = try client.loadPlugin(at: url, authorization: authorization, processContext: context)
        let adapter = PluginLanguageService()
        adapter.bind(binding, client: client)
        var command = ProcessCommand(executable: fixture.executable, directory: fixture.root)
        command.environment = fixture.environment
        var configuration = LanguageServerConfiguration(command: command, workspace: fixture.root)
        configuration.connect = { try adapter.connect($0) }
        let language = LSPClient(configuration: configuration)
        try await language.start()
        try await language.initialize()
        let text = String(repeating: "Swift 🥭\n", count: 4000)
        let params = try JSONSerialization.data(withJSONObject: ["textDocument": [
            "uri": fixture.root.appendingPathComponent("test.swift").absoluteString,
            "languageId": "swift", "version": 1, "text": text
        ]])
        try await language.notify("textDocument/didOpen", params: params)
        let burst = try await language.request("test/burst", timeout: .seconds(10))
        #expect(String(decoding: try #require(burst), as: UTF8.self) == "200")
        #expect(try fixture.openedDocuments() == [text])
        try client.unloadPlugin(at: url)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await language.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!(await language.isRunning))
        await language.stop()
        adapter.bind(nil)
        #expect(throws: (any Error).self) { try adapter.connect(command) }
    }

    @Test func packageAndGeneratedComponentMatch() throws {
        let package = try PluginPackageLoader().load(at: BundledPlugins.swiftSupport)
        #expect(package.manifest.id == "studio.swift-support")
        #expect(package.manifest.host.processes.first?.command == "sourcekit-lsp")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Plugins/SwiftSupport/component.wat"), encoding: .utf8)
        #expect(try EmbeddedWasmtimeComponentRuntime.compileComponentWAT(source) == Data(contentsOf: package.componentURL))
        let runtime = try EmbeddedWasmtimeComponentRuntime()
        try runtime.validateComponent(package, limits: .secureDefault)
        let inspection = PluginInspection(package: package, contracts: PluginWITContractDeriver.contracts(for: package))
        let binding = try PluginExecutionBinding(pluginPath: package.rootURL.path, inspection: inspection,
            authorization: PluginAuthorizationRecord(inspection: inspection), hostGeneration: 0)
        let registry = try PluginCapabilityRegistryBuilder.build(base: .aiDefault, bindings: [binding])
        #expect(registry.descriptor(for: "studio.swift-support.language-server")?.isAIExposed == false)
    }

    @Test func disabledPreferenceSurvivesReopening() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: project) }
        #expect(try BundledPlugins.disabled(in: project.path).isEmpty)
        try BundledPlugins.setEnabled(false, id: "studio.swift-support", in: project.path)
        #expect(try BundledPlugins.disabled(in: project.path) == ["studio.swift-support"])
        try BundledPlugins.setEnabled(true, id: "studio.swift-support", in: project.path)
        #expect(try BundledPlugins.disabled(in: project.path).isEmpty)
    }

    @Test func malformedPreferenceIsRejected() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: project) }
        try BundledPlugins.setEnabled(false, id: "studio.swift-support", in: project.path)
        try Data("invalid".utf8).write(to: project.appendingPathComponent(".guava/disabled_bundled_plugins.json"))
        #expect(throws: (any Error).self) { try BundledPlugins.disabled(in: project.path) }
    }
}
