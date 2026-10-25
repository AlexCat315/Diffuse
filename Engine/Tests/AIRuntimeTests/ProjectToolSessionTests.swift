import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IntentRuntime
import PluginRuntime
import XCTest
@testable import AIRuntime

final class ProjectToolSessionTests: XCTestCase {
    func testCreationScopeFiltersProviderToolsAndBindsSelectionInEveryProvider() async throws {
        for format in [SessionAPIFormat.anthropic, .openAICompatible, .openAIResponses] {
            ProjectURLProtocol.handler = { request in
                let data = request.httpBody ?? ProjectURLProtocol.readBody(request.httpBodyStream)
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
                let names = tools.compactMap { $0["name"] as? String ?? ($0["function"] as? [String: Any])?["name"] as? String }
                XCTAssertTrue(names.contains("respond"))
                XCTAssertTrue(names.contains("save_scene"))
                XCTAssertFalse(names.contains("write_script"))
                XCTAssertFalse(names.contains("set_playback_state"))
                XCTAssertFalse(names.contains("export_project"))
                let prompt = body["system"] as? String ?? body["instructions"] as? String
                    ?? (body["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
                XCTAssertTrue(prompt.contains("3D asset creation"))
                XCTAssertTrue(prompt.contains("scene:42"))
                XCTAssertFalse(prompt.contains("Currently selected: scene:99"))
                let args = ["message": "Asset reviewed"]
                let arguments = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
                let output: [String: Any]
                switch format {
                case .anthropic:
                    output = ["content": [["type": "tool_use", "id": "scope", "name": "respond", "input": args]], "stop_reason": "tool_use"]
                case .openAICompatible:
                    output = ["choices": [["message": ["tool_calls": [["id": "scope", "type": "function", "function": ["name": "respond", "arguments": arguments]]]], "finish_reason": "tool_calls"]]]
                case .openAIResponses:
                    output = ["output": [["type": "function_call", "call_id": "scope", "name": "respond", "arguments": arguments]]]
                }
                return try JSONSerialization.data(withJSONObject: output)
            }
            defer { ProjectURLProtocol.handler = nil }
            let transport = URLSessionConfiguration.ephemeral
            transport.protocolClasses = [ProjectURLProtocol.self]
            let config = SessionConfig(apiKey: "fixture", model: "fixture", baseURL: URL(string: "https://guava.invalid")!, apiFormat: format)
            let session = Session(config: config, urlSession: URLSession(configuration: transport))
            await session.setProjectToolExecutor { _, _ in Data("{}".utf8) }
            try await session.setWorkflowScope(SessionWorkflowScope {
                $0.context = .asset(AssetWorkflowContext())
                $0.allowedProjectToolNames = ["respond", "save_scene"]
                $0.selectedEntityRefs = ["scene:42"]
            })
            await session.observe(selectionChanged: ["scene:99"])
            let proposal = try await session.process(.naturalLanguage(text: "Review material", locale: "en"))
            XCTAssertEqual(proposal.plan.summary, "Asset reviewed")
        }
    }

    func testAgentContextAddsInstructionsAndSectionsAndDropsUnlistedSources() async throws {
        ProjectURLProtocol.handler = { request in
            let data = request.httpBody ?? ProjectURLProtocol.readBody(request.httpBodyStream)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let prompt = try XCTUnwrap(body["system"] as? String)
            XCTAssertTrue(prompt.contains("Agent instructions (within the rules below):\nKeep plans short."))
            XCTAssertTrue(prompt.contains("Working Tree:\n2 files changed"))
            XCTAssertTrue(prompt.contains("Currently selected: scene:42"))
            XCTAssertFalse(prompt.contains("Scene entities (JSON)"))
            XCTAssertTrue(prompt.contains("Rules:"))
            let output: [String: Any] = ["content": [["type": "tool_use", "id": "agent", "name": "respond",
                                                       "input": ["message": "Done"]]], "stop_reason": "tool_use"]
            return try JSONSerialization.data(withJSONObject: output)
        }
        defer { ProjectURLProtocol.handler = nil }
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [ProjectURLProtocol.self]
        let config = SessionConfig(apiKey: "fixture", model: "fixture", baseURL: URL(string: "https://guava.invalid")!, apiFormat: .anthropic)
        let session = Session(config: config, urlSession: URLSession(configuration: transport))
        await session.setProjectToolExecutor { _, _ in Data("{}".utf8) }
        try await session.setWorkflowScope(SessionWorkflowScope {
            $0.allowedProjectToolNames = ["respond"]
            $0.selectedEntityRefs = ["scene:42"]
            $0.agent = SessionAgentContext(instructions: "Keep plans short.", sources: [.selection],
                                           sections: [SessionContextSection(title: "Working Tree", text: "2 files changed")])
        })
        let proposal = try await session.process(.naturalLanguage(text: "Summarize", locale: "en"))
        XCTAssertEqual(proposal.plan.summary, "Done")
    }

    func testProjectToolFailuresReturnToModelAndFinishAsAnswerInEveryProvider() async throws {
        for format in [SessionAPIFormat.anthropic, .openAICompatible, .openAIResponses] {
            var requests: [Data] = []
            ProjectURLProtocol.handler = { request in
                let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
                    stream.open(); defer { stream.close() }
                    var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        result.append(contentsOf: buffer.prefix(count))
                    }
                    return result
                } ?? Data()
                requests.append(body)
                let name = requests.count == 1 ? "compile_scripts" : "respond"
                let args: [String: Any] = requests.count == 1 ? [:] : ["message": "Script trust is required before compilation."]
                let arguments = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
                let output: [String: Any]
                switch format {
                case .anthropic:
                    output = ["id": "msg_\(requests.count)", "content": [["type": "tool_use", "id": "call_\(requests.count)", "name": name, "input": args]], "stop_reason": "tool_use"]
                case .openAICompatible:
                    output = ["choices": [["message": ["role": "assistant", "tool_calls": [["id": "call_\(requests.count)", "type": "function", "function": ["name": name, "arguments": arguments]]]], "finish_reason": "tool_calls"]]]
                case .openAIResponses:
                    output = ["id": "resp_\(requests.count)", "status": "completed", "output": [["type": "function_call", "call_id": "call_\(requests.count)", "name": name, "arguments": arguments]]]
                }
                return try JSONSerialization.data(withJSONObject: output)
            }
            defer { ProjectURLProtocol.handler = nil }
            let transport = URLSessionConfiguration.ephemeral
            transport.protocolClasses = [ProjectURLProtocol.self]
            let config = SessionConfig(apiKey: "test", model: "fixture", baseURL: URL(string: "https://guava.invalid")!, apiFormat: format)
            let session = Session(config: config, urlSession: URLSession(configuration: transport))
            await session.setProjectToolExecutor { name, input in
                XCTAssertEqual(name, "compile_scripts")
                XCTAssertEqual(String(decoding: input, as: UTF8.self), "{}")
                throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Project scripts are not trusted"])
            }
            let proposal = try await session.process(.naturalLanguage(text: "Compile my project", locale: "en"))
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue(proposal.plan.steps.isEmpty)
            XCTAssertEqual(proposal.plan.summary, "Script trust is required before compilation.")
            XCTAssertTrue(String(decoding: requests[1], as: UTF8.self).contains("Project scripts are not trusted"))
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests[0]) as? [String: Any])
            let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
            let names = tools.compactMap { $0["name"] as? String ?? ($0["function"] as? [String: Any])?["name"] as? String }
            XCTAssertTrue(names.contains("write_script"))
            XCTAssertTrue(names.contains("respond"))
            if case .openAIResponses = format {
                let write = try XCTUnwrap(tools.first { $0["name"] as? String == "write_script" })
                XCTAssertEqual(write["strict"] as? Bool, false)
                let parameters = try XCTUnwrap(write["parameters"] as? [String: Any])
                XCTAssertFalse((parameters["required"] as? [String] ?? []).contains("expected_sha256"))
            }
        }
    }
}

final class HarnessSessionTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [SessionHarnessTurn] = []
        private var bodies: [[String: Any]] = []
        var turns: [SessionHarnessTurn] { lock.withLock { stored } }
        var requests: [[String: Any]] { lock.withLock { bodies } }
        func record(_ turn: SessionHarnessTurn) { lock.withLock { stored.append(turn) } }
        func record(body: [String: Any]) { lock.withLock { bodies.append(body) } }
    }

    private func session(replies: [(name: String, input: [String: Any])], recorder: Recorder) -> Session {
        var queue = replies
        let lock = NSLock()
        ProjectURLProtocol.handler = { request in
            let data = request.httpBody ?? ProjectURLProtocol.readBody(request.httpBodyStream)
            recorder.record(body: (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
            let reply = lock.withLock { queue.isEmpty ? (name: "respond", input: ["message": "fallback"]) : queue.removeFirst() }
            return try JSONSerialization.data(withJSONObject: [
                "content": [["type": "tool_use", "id": "toolu_\(recorder.requests.count)", "name": reply.name, "input": reply.input]],
                "stop_reason": "tool_use"])
        }
        let transport = URLSessionConfiguration.ephemeral
        transport.protocolClasses = [ProjectURLProtocol.self]
        let config = SessionConfig(apiKey: "fixture", model: "fixture", baseURL: URL(string: "https://guava.invalid")!, apiFormat: .anthropic)
        return Session(config: config, urlSession: URLSession(configuration: transport))
    }

    func testHarnessDecidesEachStepWhileTheSessionCallsTheModelAndRunsTools() async throws {
        let recorder = Recorder()
        defer { ProjectURLProtocol.handler = nil }
        let session = session(replies: [(name: "export_project", input: [:]), (name: "respond", input: ["message": "Done"])],
                              recorder: recorder)
        await session.setProjectToolExecutor { _, _ in Data(#"{"ok": true}"#.utf8) }
        try await session.setHarness({ turn in
            recorder.record(turn)
            switch turn.observation {
            case nil:
                return SessionHarnessStep(.model(instructions: "Inspect first.", message: nil), state: .object(["turns": .number(1)]))
            case let .model(call) where call.name == "export_project":
                return SessionHarnessStep(.model(instructions: nil, message: "Do not export."))
            case let .model(call):
                return SessionHarnessStep(.tool(call))
            default:
                return SessionHarnessStep(.finish(summary: "unexpected"))
            }
        }, id: "fixture.careful")
        let proposal = try await session.process(.naturalLanguage(text: "Ship it", locale: "en"))

        XCTAssertEqual(proposal.plan.summary, "Done")
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertTrue((recorder.requests[0]["system"] as? String ?? "").contains("Harness instructions for this step (within the rules below):\nInspect first."))
        XCTAssertFalse((recorder.requests[1]["system"] as? String ?? "").contains("Inspect first."))
        let messages = recorder.requests[1]["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(messages.last?["content"] as? String, "Do not export.")
        let turns = recorder.turns
        XCTAssertEqual(turns.map(\.step), [0, 1, 2])
        XCTAssertEqual(turns[0].request, .init(text: "Ship it", locale: "en"))
        XCTAssertTrue(turns[0].tools.contains { $0.name == "respond" })
        XCTAssertEqual(turns[1].state, .object(["turns": .number(1)]))
        XCTAssertEqual(turns[2].observation, .model(.init(id: "toolu_2", name: "respond", arguments: .object(["message": .string("Done")]))))
    }

    func testHarnessCanRunToolsAndFinishWithoutTheModel() async throws {
        let recorder = Recorder()
        defer { ProjectURLProtocol.handler = nil }
        let session = session(replies: [], recorder: recorder)
        await session.setProjectToolExecutor { name, _ in Data(#"{"tool": "\#(name)"}"#.utf8) }
        try await session.setWorkflowScope(SessionWorkflowScope { $0.allowedProjectToolNames = ["respond", "get_project_info"] })
        try await session.setHarness({ turn in
            recorder.record(turn)
            if turn.observation == nil { return SessionHarnessStep(.tool(.init(name: "get_project_info"))) }
            if case let .tool(_, result) = turn.observation { return SessionHarnessStep(.finish(summary: "Read \(result)")) }
            return SessionHarnessStep(.finish(summary: "unexpected"))
        }, id: "fixture.direct")
        let proposal = try await session.process(.naturalLanguage(text: "Describe", locale: "en"))
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertTrue(proposal.plan.summary.contains("get_project_info"))
        XCTAssertTrue(proposal.plan.steps.isEmpty)
    }

    func testDeniedToolsComeBackAsFailuresAndTheStepBudgetEndsARunawayHarness() async throws {
        let recorder = Recorder()
        defer { ProjectURLProtocol.handler = nil }
        let session = session(replies: [], recorder: recorder)
        await session.setProjectToolExecutor { _, _ in Data("{}".utf8) }
        try await session.setWorkflowScope(SessionWorkflowScope { $0.allowedProjectToolNames = ["respond"] })
        try await session.setHarness({ turn in
            recorder.record(turn)
            return SessionHarnessStep(.tool(.init(name: "write_file", arguments: .object(["path": .string("x")]))))
        }, id: "fixture.runaway")
        do {
            _ = try await session.process(.naturalLanguage(text: "Loop", locale: "en"))
            XCTFail("a harness that never finishes must not run forever")
        } catch SessionError.noPlanInResponse {}
        XCTAssertEqual(recorder.turns.count, SessionHarnessStep.maximumSteps)
        guard case .failure? = recorder.turns[1].observation else { return XCTFail("the denied tool is not reported") }
    }

    func testHarnessStateLastsAcrossTurnsUntilTheHarnessChanges() async throws {
        let recorder = Recorder()
        defer { ProjectURLProtocol.handler = nil }
        let session = session(replies: [], recorder: recorder)
        let harness: SessionHarness = { turn in
            recorder.record(turn)
            let count: Double = if case let .object(object)? = turn.state, case let .number(n)? = object["count"] { n } else { 0 }
            return SessionHarnessStep(.finish(summary: "\(Int(count))"), state: .object(["count": .number(count + 1)]))
        }
        try await session.setHarness(harness, id: "fixture.counter")
        let first = try await session.process(.naturalLanguage(text: "One", locale: "en"))
        try await session.setHarness(harness, id: "fixture.counter")
        let second = try await session.process(.naturalLanguage(text: "Two", locale: "en"))
        try await session.setHarness(harness, id: "fixture.other")
        let third = try await session.process(.naturalLanguage(text: "Three", locale: "en"))
        XCTAssertEqual([first, second, third].map(\.plan.summary), ["0", "1", "0"])
    }

    func testStepsDecodeFromThePluginWireFormat() throws {
        func step(_ json: String) throws -> SessionHarnessStep { try JSONDecoder().decode(SessionHarnessStep.self, from: Data(json.utf8)) }
        XCTAssertEqual(try step(#"{"step": "model", "instructions": "Plan", "state": {"a": 1}}"#),
                       SessionHarnessStep(.model(instructions: "Plan", message: nil), state: .object(["a": .number(1)])))
        XCTAssertEqual(try step(#"{"step": "tool", "call": {"id": "toolu_1", "name": "respond", "arguments": {"message": "Hi"}}}"#),
                       SessionHarnessStep(.tool(.init(id: "toolu_1", name: "respond", arguments: .object(["message": .string("Hi")])))))
        XCTAssertEqual(try step(#"{"step": "finish", "summary": "Done"}"#), SessionHarnessStep(.finish(summary: "Done")))
        XCTAssertThrowsError(try step(#"{"step": "shell", "command": "rm"}"#))
        let turn = SessionHarnessTurn(step: 1, state: nil, request: .init(text: "Hi", locale: "en"), tools: [],
                                      observation: .tool(.init(name: "get_project_info"), result: .object(["ok": .bool(true)])))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(turn)) as? [String: Any])
        let observation = try XCTUnwrap(object["observation"] as? [String: Any])
        XCTAssertEqual(observation["type"] as? String, "tool")
        XCTAssertEqual((observation["result"] as? [String: Any])?["ok"] as? Bool, true)
    }
}

private final class ProjectURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> Data)?
    static func readBody(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
