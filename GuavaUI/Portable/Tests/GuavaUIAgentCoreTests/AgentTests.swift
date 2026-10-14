import Foundation
import Testing
@testable import GuavaUIAgentCore

@Suite("Portable agent foundation")
struct AgentTests {
    private var echo: AgentTool {
        AgentTool(name: "echo", description: "Return supplied text",
            schema: .object(properties: ["text": .string()], required: ["text"], additionalProperties: false))
    }
    private func toolbox() throws -> AgentToolbox {
        try AgentToolbox(tools: [echo]) { _, input in AgentToolResult(json: input) }
    }

    @Test func validatesBeforeExecutingAndBoundsResults() async throws {
        let toolbox = try toolbox()
        await #expect(throws: JSONSchemaViolation.self) {
            _ = try await toolbox.execute(name: "echo", input: Data(#"{"text":12}"#.utf8))
        }
        await #expect(throws: AgentError.self) {
            _ = try await toolbox.execute(name: "unregistered", input: Data("{}".utf8))
        }
        let invalid = try AgentToolbox(tools: [echo]) { _, _ in AgentToolResult(json: Data("invalid".utf8)) }
        await #expect(throws: AgentError.self) {
            _ = try await invalid.execute(name: "echo", input: Data(#"{"text":"ok"}"#.utf8))
        }
    }

    @Test func modelReceivesRealToolResultsAndExplicitSkillContext() async throws {
        let library = try AgentSkillLibrary(skills: [AgentSkill(name: "inspect", description: "Inspect app",
            instructions: "Read state before forming a diagnosis.")])
        let session = try AgentSession(toolbox: toolbox(), skills: library, enabledSkills: ["inspect"]) { messages, tools in
            #expect(tools.map(\.name) == ["echo"])
            #expect(messages.first?.text.contains("Read state") == true)
            if let result = messages.last, result.role == .tool {
                #expect(result.resultFor == "call1" && !result.isError)
                #expect(result.text == #"{"text":"measured"}"#)
                return .answer("Verified")
            }
            return .tools([AgentToolCall(id: "call1", name: "echo", arguments: Data(#"{"text":"measured"}"#.utf8))])
        }
        let run = try await session.run(messages: [AgentMessage(role: .user, text: "Inspect")])
        #expect(run.answer == "Verified" && run.toolRounds == 1)
    }

    @Test func mcpNegotiatesListsCallsAndExposesSkillsAsPrompts() async throws {
        let library = try AgentSkillLibrary(skills: [AgentSkill(name: "inspect", description: "Inspect", instructions: "Observe first")])
        let server = MCPServer(name: "fixture", version: "1", toolbox: try toolbox(), skills: library)
        let notification = await server.respond(to: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(notification == nil)
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":"ok"}}}"#.utf8)
        let response = try #require(await server.respond(to: request))
        let json = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try #require(json["result"] as? [String: Any])
        #expect((result["structuredContent"] as? [String: String])?["text"] == "ok")
        #expect(result["isError"] as? Bool == false)
        let skill = try #require(await server.respond(to: Data(#"{"jsonrpc":"2.0","id":2,"method":"prompts/get","params":{"name":"inspect"}}"#.utf8)))
        #expect(String(decoding: skill, as: UTF8.self).contains("Observe first"))
        let badID = try #require(await server.respond(to: Data(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#.utf8)))
        #expect(String(decoding: badID, as: UTF8.self).contains("-32600"))
        let invalid = try #require(await server.respond(to: Data(#"{"id":42,"method":"ping"}"#.utf8)))
        let errorResponse = try #require(JSONSerialization.jsonObject(with: invalid) as? [String: Any])
        #expect(errorResponse["id"] as? Int == 42)
    }

    @Test func toolRoundLimitAndCancellationAreEnforced() async throws {
        let looping = try AgentSession(toolbox: toolbox(), maximumToolRounds: 1) { _, _ in
            .tools([AgentToolCall(id: "loop", name: "echo", arguments: Data(#"{"text":"ok"}"#.utf8))])
        }
        await #expect(throws: AgentError.self) { _ = try await looping.run(messages: []) }
        let cancellation = try AgentSession(toolbox: toolbox()) { _, _ in
            try? await Task.sleep(for: .seconds(5))
            return .answer("Ignored cancellation")
        }
        let task = Task { try await cancellation.run(messages: []) }
        await Task.yield()
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func skillDirectoryRejectsEscapingSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("inspect"), withIntermediateDirectories: true)
        try "---\nname: inspect\ndescription: Inspect\n---\nObserve first".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("inspect/SKILL.md"), withDestinationURL: outside)
        #expect(throws: AgentError.self) { _ = try AgentSkillLibrary.load(directory: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("inspect/SKILL.md"))
        try FileManager.default.copyItem(at: outside, to: root.appendingPathComponent("inspect/SKILL.md"))
        #expect(try AgentSkillLibrary.load(directory: root).read(name: "inspect").instructions == "Observe first")
    }
}
