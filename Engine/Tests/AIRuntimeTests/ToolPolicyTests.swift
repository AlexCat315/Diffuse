import AIRuntime
import CapabilityRuntime
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@Suite("Tool policy", .serialized)
struct ToolPolicyTests {
    private struct TestError: Error {}

    @Test("an empty policy is a pass-through and handlers fold in order")
    func policySemantics() throws {
        let call = ToolCall(name: "write_file",
                            arguments: Data(#"{"path":"a"}"#.utf8),
                            origin: .mcp)
        #expect(try ToolPolicy().evaluate(call) == call)

        let rewritten = try ToolPolicy(handlers: [
            { request in
                .allow(ToolCall(name: request.name,
                                arguments: Data(#"{"path":"b"}"#.utf8),
                                origin: request.origin))
            },
        ]).evaluate(call)
        #expect(rewritten.arguments == Data(#"{"path":"b"}"#.utf8))

        // The first denial short-circuits: if the third handler ran, evaluate
        // would return normally and the expectation below would fail.
        let denial = ToolPolicyDenial(code: .untrustedProject, reason: "project is untrusted")
        let denying = ToolPolicy(handlers: [
            { request in .allow(request) },
            { _ in .deny(denial) },
            { request in .allow(request) },
        ])
        #expect(throws: ToolPolicyError.denied(denial)) {
            try denying.evaluate(call)
        }

        // Handler errors propagate unchanged.
        #expect(throws: TestError.self) {
            try ToolPolicy(handlers: [{ _ in throw TestError() }]).evaluate(call)
        }
    }

    @Test("a session denial covers capability and inline tools and planning continues",
          arguments: [CapabilityToolset.searchToolName, "execute_edit_plan", "find_entities"])
    func sessionDenialIsAnObservation(toolName: String) async throws {
        PolicyURLProtocol.reset(firstToolName: toolName)
        let denial = ToolPolicyDenial(code: .mode, reason: "blocked by test policy")
        let policy = ToolPolicy(handlers: [{ call in
            String(decoding: call.arguments, as: UTF8.self).contains("query")
                ? .deny(denial) : .allow(call)
        }])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PolicyURLProtocol.self]
        let session = Session(config: .openAIResponses(apiKey: "test"),
                              urlSession: URLSession(configuration: configuration),
                              toolPolicy: policy)

        let proposal = try await session.process(.naturalLanguage(text: "Rename an entity",
                                                                  locale: "en"))
        #expect(proposal.plan.summary == "No changes")
        #expect(PolicyURLProtocol.requestCount == 2)
        #expect(PolicyURLProtocol.secondRequestContainedDenial == true)
    }

    @Test("policies cannot rewrite tool identity or silently discard invalid arguments")
    func invalidRewritesFailClosed() async throws {
        let call = ToolCall(name: "read", arguments: Data("{}".utf8), origin: .mcp)
        #expect(throws: ToolPolicyError.invalidRewrite) {
            try ToolPolicy(handlers: [{ _ in .allow(ToolCall(
                name: "write", arguments: call.arguments, origin: call.origin
            )) }]).evaluate(call)
        }
        PolicyURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PolicyURLProtocol.self]
        let session = Session(config: .openAIResponses(apiKey: "test"),
            urlSession: URLSession(configuration: configuration),
            toolPolicy: ToolPolicy(handlers: [{ call in
                guard call.name == CapabilityToolset.searchToolName else { return .allow(call) }
                var next = call
                next.arguments = Data("invalid JSON".utf8)
                return .allow(next)
            }]))
        _ = try await session.process(.naturalLanguage(text: "Inspect", locale: "en"))
        #expect(PolicyURLProtocol.secondRequestContainedDenial == true)
    }

    @Test("draft creation denies and rewrites through the store policy")
    func storePolicyDeniesAndRewrites() async throws {
        let sessionID = UUID().uuidString
        let denied = CapabilityExposureSessionStore(
            toolPolicy: ToolPolicy(handlers: [
                { _ in .deny(ToolPolicyDenial(code: .policy, reason: "blocked by test policy")) },
            ])
        )
        let activation = try await denied.search(sessionID: sessionID,
                                                 query: "rename",
                                                 sceneRevision: 5)
        let rename = try #require(activation.contracts.first { $0.id == "scene.set_name" })
        await #expect(throws: ToolPolicyError.denied(
            ToolPolicyDenial(code: .policy, reason: "blocked by test policy")
        )) {
            try await denied.createDraft(
                sessionID: sessionID,
                toolName: rename.toolName,
                input: Data(#"{"entity_id":"scene:1","name":"Blocked"}"#.utf8),
                sceneRevision: 5
            )
        }

        let rewrittenSessionID = UUID().uuidString
        let rewritten = CapabilityExposureSessionStore(
            toolPolicy: ToolPolicy(handlers: [
                { call in
                    guard call.origin == .mcp else { return .allow(call) }
                    return .allow(ToolCall(name: call.name,
                                           arguments: Data(#"{"entity_id":"scene:1","name":"Rewritten"}"#.utf8),
                                           origin: call.origin))
                },
            ])
        )
        let rewriteActivation = try await rewritten.search(sessionID: rewrittenSessionID,
                                                           query: "rename",
                                                           sceneRevision: 5)
        let rewriteContract = try #require(rewriteActivation.contracts.first {
            $0.id == "scene.set_name"
        })
        let draft = try await rewritten.createDraft(
            sessionID: rewrittenSessionID,
            toolName: rewriteContract.toolName,
            input: Data(#"{"entity_id":"scene:1","name":"Original"}"#.utf8),
            sceneRevision: 5
        )
        let decoded = try #require(
            JSONSerialization.jsonObject(with: draft.validatedInput) as? [String: Any]
        )
        #expect(decoded["name"] as? String == "Rewritten")
    }
}

/// First request asks for a capability search; the second one captures the
/// request body (which must now carry the policy denial) and finishes the plan.
private final class PolicyURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestCountStorage = 0
    nonisolated(unsafe) private static var denialSeen = false
    nonisolated(unsafe) private static var firstToolName = CapabilityToolset.searchToolName

    static var requestCount: Int { lock.withLock { requestCountStorage } }
    static var secondRequestContainedDenial: Bool? {
        lock.withLock { requestCountStorage >= 2 ? denialSeen : nil }
    }

    static func reset(firstToolName: String = CapabilityToolset.searchToolName) {
        lock.withLock {
            requestCountStorage = 0
            denialSeen = false
            Self.firstToolName = firstToolName
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let callNumber = Self.lock.withLock { () -> Int in
            Self.requestCountStorage += 1
            return Self.requestCountStorage
        }
        let responseObject: [String: Any]
        if callNumber == 1 {
            responseObject = ["output": [[
                "type": "function_call",
                "call_id": "search_1",
                "name": Self.lock.withLock { Self.firstToolName },
                "arguments": #"{"query":"rename"}"#,
            ]]]
        } else {
            let bodyData = Self.bodyData(from: request) ?? Data()
            let body = String(decoding: bodyData, as: UTF8.self)
            Self.lock.withLock {
                Self.denialSeen = body.contains("Tool call denied")
            }
            responseObject = ["output": [[
                "type": "function_call",
                "call_id": "final_1",
                "name": "execute_edit_plan",
                "arguments": #"{"summary":"No changes","steps":[]}"#,
            ]]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: responseObject) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
            return
        }
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: 200,
                                       httpVersion: nil,
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
