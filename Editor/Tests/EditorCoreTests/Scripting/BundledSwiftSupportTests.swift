import Foundation
import Testing
import PluginRuntime
import PluginWasmtimeRuntime
import CapabilityRuntime
import LanguageServerRuntime
internal import CoveProcess
import CoveUICompose
@testable import EditorCore

@Suite("Bundled Swift Support")
struct BundledSwiftSupportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COVE_TEST_REAL_SOURCEKIT"] == "1"), .timeLimit(.minutes(3)))
    func realSourceKitSemanticQueries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appendingPathComponent("Scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let file = DynamicScriptManager.ScriptFile(url: scripts.appendingPathComponent("Example.swift"))
        let toolchain = try SwiftToolchainResolver.resolve()
        let configuration = ProjectScriptBuildConfiguration.discover(for: toolchain.compilerURL)
        let imports = configuration.engineModulePaths.isEmpty ? "" : "import ScriptRuntime\nimport SceneRuntime\n"
        if !configuration.engineModulePaths.isEmpty {
            try await toolchain.validateAnalysis(engineModulePaths: configuration.engineModulePaths,
                clangModuleMapPaths: configuration.clangModuleMapPaths, clangIncludePaths: configuration.clangIncludePaths)
        }
        let firstLine = imports.isEmpty ? 0 : 2
        let source = imports + "let greeting = \"hello\"\ngreeting.\n"
        try Data(source.utf8).write(to: file.url)
        let executable = toolchain.languageServerURL
        let client = PluginHostProcessClient(executableURL: try #require(EditorPluginHostLocator.resolve()))
        defer { client.stop() }
        let inspection = try client.inspectPlugin(at: try #require(BundledPlugins.languageServer))
        var context = PluginProcessContext(workspace: root)
        context.executables = ["sourcekit-lsp": executable]
        let binding = try client.loadPlugin(at: try #require(BundledPlugins.languageServer),
            authorization: PluginAuthorizationRecord(inspection: inspection), processContext: context)
        let adapter = PluginLanguageService()
        adapter.bind(binding, client: client)
        let support = ScriptLanguageSupport(scriptsDirectoryURL: scripts, engineModulePaths: configuration.engineModulePaths,
            clangModuleMapPaths: configuration.clangModuleMapPaths, clangIncludePaths: configuration.clangIncludePaths,
            executableURL: executable, environment: toolchain.environment, connect: { try adapter.connect($0) })
        try await support.start(sources: [ScriptLanguageSource(file: file, text: TextBuffer(source))], onDiagnostics: { _ in })
        do {
            var completion = ScriptCompletionResult(items: [], isIncomplete: false)
            for _ in 0..<8 {
                completion = try await support.completion(scriptID: file.identifier, at: .init(line: firstLine + 1, character: 9))
                if !completion.items.isEmpty { break }
                try await Task.sleep(for: .seconds(1))
            }
            #expect(completion.items.contains { $0.label.contains("uppercased") })
            var hover: ScriptHoverResult?
            for _ in 0..<8 {
                hover = try await support.hover(scriptID: file.identifier, at: .init(line: firstLine, character: 6))
                if hover?.contents.contains("String") == true { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(hover?.contents.contains("String") == true)
            var edited = ScriptLanguageSource(file: file, text: TextBuffer(imports
                + "func greet(_ name: String) -> String { name }\nlet message = greet(\"hello\")\n"))
            edited.revision = 1
            try await support.update(scriptID: file.identifier, text: edited.text, revision: edited.revision)
            var locations: [ScriptDefinitionLocation] = []
            for _ in 0..<8 {
                locations = try await support.definition(scriptID: file.identifier, at: .init(line: firstLine + 1, character: 16))
                if locations.contains(where: { $0.scriptID == file.identifier }) { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(locations.contains { $0.scriptID == file.identifier && $0.span.start.line == firstLine },
                "Definition locations: \(String(describing: locations))")
            let symbols = try await support.documentSymbols(scriptID: file.identifier)
            #expect(symbols.contains { $0.name.contains("greet") })
            let preparation = try await support.prepareRename(scriptID: file.identifier, at: .init(line: firstLine, character: 6))
            #expect(preparation != nil)
            let rename = try await support.rename(scriptID: file.identifier, at: .init(line: firstLine, character: 6), newName: "welcome")
            #expect(rename.documents.first?.scriptID == file.identifier)
            #expect(rename.documents.first?.sourceRevision == 1)
            #expect((rename.documents.first?.edits.count ?? 0) >= 2)
            let typeLocations = try await support.definition(scriptID: file.identifier, at: .init(line: firstLine, character: 21))
            for location in typeLocations where URL(string: location.documentURI)?.scheme == "sourcekit-lsp" {
                let reference = try await support.referenceDocument(documentURI: location.documentURI)
                #expect(reference?.contains("String") == true)
            }
            let formatted = try await support.formatting(scriptID: file.identifier)
            #expect(formatted.documents.allSatisfy { $0.scriptID == file.identifier && $0.sourceRevision == 1 })
            let details = await support.languageServiceDetails()
            #expect(details.health == .healthy)
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
            environment: ["COVE_BUILD_PRODUCTS_PATH": products.path])
        #expect(configuration.engineModulePaths == [products.path])
        let overridden = ProjectScriptBuildConfiguration.discover(for: executable,
            environment: ["COVE_BUILD_PRODUCTS_PATH": products.path, "COVE_ENGINE_MODULE_PATHS": "/SDK/Modules"])
        #expect(overridden.engineModulePaths == ["/SDK/Modules"])
    }

    @Test(.timeLimit(.minutes(1))) func isolatedLanguageServerRoundTripAndUnload() async throws {
        let fixture = try LSPProcessFixture()
        defer { fixture.remove() }
        let host = try #require(EditorPluginHostLocator.resolve())
        let client = PluginHostProcessClient(executableURL: host)
        defer { client.stop() }
        let url = fixture.root.appendingPathComponent("SwiftSupport.coveplugin")
        try FileManager.default.copyItem(at: try #require(BundledPlugins.languageServer), to: url)
        var manifest = try JSONDecoder().decode(CovePluginManifest.self, from: Data(contentsOf: url.appendingPathComponent("plugin.json")))
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
        command.environment = ProcessInfo.processInfo.environment.merging(fixture.environment) { _, value in value }
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
        let large = try #require(try await language.request("test/large", timeout: .seconds(15)))
        #expect(try JSONSerialization.jsonObject(with: large, options: [.fragmentsAllowed]) as? String
            == String(repeating: "Swift 🥭\n", count: 80_000))
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

    /// Bundled packages are built from `Editor/Plugins/<Name>` with `cove plugin build`;
    /// their manifests and contracts must be the sources'.
    @Test func bundledPackagesMatchTheirSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for package in BundledPlugins.catalog.map(\.package) {
            // Sources are grouped by domain (`Plugins/Themes/Default`), while a
            // package file may sit at either depth.
            let name = package.deletingPathExtension().lastPathComponent
            let manifestID = try #require(try? PluginPackageLoader().load(at: package)).manifest.id
            let plugins = root.appendingPathComponent("Plugins")
            let candidates = ((try? FileManager.default.subpathsOfDirectory(atPath: plugins.path)) ?? [])
                .filter { $0.hasSuffix("plugin.json") }
                .map { plugins.appendingPathComponent($0).deletingLastPathComponent() }
            let source = candidates.first { directory in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("plugin.json")),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return false
                }
                return object["id"] as? String == manifestID
            } ?? plugins.appendingPathComponent(name)
            // Declarative packages own no component, so they ship no contract.
            let shipsContract = FileManager.default.fileExists(
                atPath: package.appendingPathComponent("capabilities.wit").path)
            for file in ["plugin.json"] + (shipsContract ? ["capabilities.wit"] : []) {
                #expect(try Data(contentsOf: source.appendingPathComponent(file)) == Data(contentsOf: package.appendingPathComponent(file)),
                        "\(package.lastPathComponent)/\(file) is out of date; run cove plugin build")
            }
        }
    }

    @Test func packageComponentHonorsItsContract() throws {
        let package = try PluginPackageLoader().load(at: try #require(BundledPlugins.languageServer))
        #expect(package.manifest.id == "studio.swift-support")
        #expect(package.manifest.host.processes.first?.command == "sourcekit-lsp")
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
        try Data("invalid".utf8).write(to: project.appendingPathComponent(".cove/disabled_bundled_plugins.json"))
        #expect(throws: (any Error).self) { try BundledPlugins.disabled(in: project.path) }
    }
}
