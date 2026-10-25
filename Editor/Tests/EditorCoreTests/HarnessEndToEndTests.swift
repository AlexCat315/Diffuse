import AIRuntime
@testable import EditorCore
import Foundation
import PluginRuntime
import Testing

/// The example Careful Agent's harness, built to WebAssembly and run in a real
/// plugin host. Build it with
/// `./guava studio plugin-build examples/Plugins/CarefulAgent --output <path>`
/// and point `GUAVA_CAREFUL_AGENT_PLUGIN` at it.
@Suite("Harness end to end", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["GUAVA_CAREFUL_AGENT_PLUGIN"] != nil))
@MainActor
struct HarnessEndToEndTests {
    @Test func carefulHarnessLooksFirstAndRefusesExport() async throws {
        let package = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GUAVA_CAREFUL_AGENT_PLUGIN"]))
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }
        let app = try EditorApplication(projectDirectory: project.path, seedPreviewScene: false,
                                        trustedPluginHostExecutableURL: try #require(EditorPluginHostLocator.resolve()))
        defer { app.shutdown() }
        let inspection = try app.inspectPlugin(at: package)
        _ = try await app.enablePlugin(at: package, authorization: try app.makePluginAuthorization(afterUserApprovalOf: inspection))
        #expect(app.agentCatalog.agent(id: "careful")?.harness == "careful")
        var settings = app.store.state.assistant.aiSettings
        settings.agentID = "careful"
        app.store.dispatch(.setAISettings(settings))

        let harness = try #require(try app.agentHarness())
        #expect(harness.id == "example.careful-agent.careful")
        func turn(_ step: Int, _ observation: SessionHarnessTurn.Observation?) -> SessionHarnessTurn {
            SessionHarnessTurn(step: step, state: nil, request: .init(text: "Brighten the lamp", locale: "en"),
                               tools: [.init(name: "respond", description: "Answer", inputSchema: nil)], observation: observation)
        }
        guard case let .model(instructions, _) = try await harness.driver(turn(0, nil)).action else {
            Issue.record("the first step does not ask the model"); return
        }
        #expect(instructions?.contains("inspecting") == true)

        let export = SessionHarnessTurn.Call(id: "toolu_1", name: "export_project", arguments: .object([:]))
        guard case let .model(_, message) = try await harness.driver(turn(1, .model(export))).action else {
            Issue.record("export is not refused"); return
        }
        #expect(message?.contains("does not export") == true)

        let read = SessionHarnessTurn.Call(id: "toolu_2", name: "get_project_info", arguments: .object([:]))
        #expect(try await harness.driver(turn(2, .model(read))).action == .tool(read))
    }
}
