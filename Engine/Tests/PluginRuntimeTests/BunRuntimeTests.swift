import Foundation
import CapabilityRuntime
@testable import PluginRuntime
import Testing

@Suite("Bun desktop plugin runtime")
struct BunRuntimeTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    @Test("the public Bun contract supplies strict input schemas without executing code")
    func contract() throws {
        let contract = try BunPluginContract.decode(Data(#"{"version":1,"entries":[{"name":"inspect","title":"Inspect","description":"","input":{"record":{"enabled":"bool","name":"string"}}}]}"#.utf8), imports: [])
        let schema = try #require(contract.capabilityInputs.first?.inputSchema)
        try JSONSchemaValidator.validate(data: Data(#"{"enabled":true,"name":"你好"}"#.utf8), against: schema)
        #expect(throws: (any Error).self) { try JSONSchemaValidator.validate(data: Data(#"{"enabled":1,"name":"x"}"#.utf8), against: schema) }
        #expect(throws: (any Error).self) { try JSONSchemaValidator.validate(data: Data(#"{"enabled":true,"name":"x","extra":1}"#.utf8), against: schema) }
    }

    @Test("the packaged native broker executes the actual AI plugin and serves host calls")
    func packagedBroker() throws {
        #if os(macOS)
        let executable = repository.appendingPathComponent("Editor/.build/mac/debug/EditorApp.app/Contents/Helpers/DiffusePluginHost")
        #elseif os(Windows)
        let executable = repository.appendingPathComponent("Editor/.build/debug/DiffusePluginHost.exe")
        #else
        let executable = repository.appendingPathComponent("Editor/.build/debug/DiffusePluginHost")
        #endif
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("bun-ai-\(UUID())")
        defer { try? FileManager.default.removeItem(at: storage) }
        let client = PluginHostProcessClient(executableURL: executable)
        defer { client.stop() }
        client.onHostCall = { call in
            // Reentrant status reads must not acquire the in-flight request lock.
            #expect(client.generation == 0)
            #expect(call.permission == PluginImportPermission.service.rawValue)
            return Data("[]".utf8)
        }
        let package = repository.appendingPathComponent("Editor/Sources/EditorCore/Resources/Plugins/AI.coveplugin")
        let inspection = try client.inspectPlugin(at: package)
        let binding = try client.loadPlugin(at: package, authorization: PluginAuthorizationRecord(inspection: inspection))
        let context = try JSONSerialization.data(withJSONObject: ["storage": storage.path, "workspace": "", "projects": [], "content": "files"])
        let input = try JSONEncoder().encode(["view": "assistant", "state": "", "event": "", "context": String(decoding: context, as: UTF8.self)])
        let result = try client.prepareCapability(binding: binding, capabilityID: "studio.ai.view", input: input, querySnapshot: nil)
        guard case let .read(payload) = result else { Issue.record("Expected view result"); return }
        let view = try PluginViewResult(json: payload, panels: ["assistant"])
        #expect(view.ui.isValid())
        #expect(view.refreshAfterMilliseconds == 500)
        try client.unloadPlugin(at: package)
    }
}
