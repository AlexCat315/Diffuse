import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IntentRuntime
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
