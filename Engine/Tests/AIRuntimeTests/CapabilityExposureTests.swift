import AIRuntime
import CapabilityRuntime
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IntentRuntime
import SceneRuntime
import Testing

@Suite("AI capability exposure")
struct CapabilityExposureTests {
    @Test("OpenAI Responses uses flat tools generated from capability contracts")
    func openAIResponsesUsesGeneratedContracts() async throws {
        ResponsesURLProtocol.handler = { request in
            let bodyData = try #require(ResponsesURLProtocol.bodyData(from: request))
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            #expect(request.url?.path == "/v1/responses")
            #expect(body["instructions"] is String)
            #expect(body["input"] is [[String: Any]])
            let tools = try #require(body["tools"] as? [[String: Any]])
            #expect(tools.allSatisfy { $0["type"] as? String == "function" })
            #expect(tools.contains { $0["name"] as? String == CapabilityToolset.searchToolName })
            let response: [String: Any] = [
                "output": [[
                    "type": "function_call",
                    "call_id": "call_responses_1",
                    "name": "execute_edit_plan",
                    "arguments": "{\"summary\":\"No changes\",\"steps\":[]}",
                ]],
            ]
            let data = try JSONSerialization.data(withJSONObject: response)
            let http = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
            return (http, data)
        }
        defer { ResponsesURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponsesURLProtocol.self]
        let session = Session(config: .openAIResponses(apiKey: "test"),
                              urlSession: URLSession(configuration: configuration))

        let proposal = try await session.process(.naturalLanguage(text: "Inspect the scene", locale: "en"))
        #expect(proposal.plan.summary == "No changes")
    }

    @Test("invalid capability parameters are offered exactly two repairs")
    func parameterRepairIsBounded() async throws {
        RepairURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RepairURLProtocol.self]
        let session = Session(config: .openAIResponses(apiKey: "test"),
                              urlSession: URLSession(configuration: configuration))

        await #expect(throws: CapabilityDraftError.self) {
            try await session.process(.naturalLanguage(text: "Rename an entity", locale: "en"))
        }
        #expect(RepairURLProtocol.requestCount == 4)
    }

    @Test("every legacy scene operation maps to one registered strict contract")
    func allSceneOperationsHaveContracts() throws {
        for operation in SceneEditOp.allCases {
            let descriptor = try #require(
                CapabilityRegistry.default.descriptor(for: operation.capabilityID),
                "missing capability for \(operation.rawValue)"
            )
            #expect(descriptor.isAIExposed)
            #expect(descriptor.contract.inputSchema.additionalProperties == false)
            #expect(!descriptor.access.isWrite || descriptor.contract.inputSchema.isStrictCapabilityInput)
            #expect(!descriptor.contract.schemaHash.isEmpty)
        }
        try CapabilityRegistry.default.validateIntegrity()
    }

    @Test("schema hash changes when contract constraints change")
    func schemaHashBindsConstraints() {
        let original = CapabilityContract(id: "test.range",
                                          title: "Range",
                                          description: "Test",
                                          domain: "test",
                                          access: .read,
                                          releasePhase: .stable,
                                          inputSchema: .object(properties: [
                                            "value": .number(minimum: 0, maximum: 1),
                                          ], required: ["value"]))
        let changed = CapabilityContract(id: "test.range",
                                         title: "Range",
                                         description: "Test",
                                         domain: "test",
                                         access: .read,
                                         releasePhase: .stable,
                                         inputSchema: .object(properties: [
                                            "value": .number(minimum: 0, maximum: 2),
                                         ], required: ["value"]))
        #expect(original.schemaHash != changed.schemaHash)
        #expect(original.toolName != changed.toolName)
    }

    @Test("write tools create drafts without changing the scene and stale revisions fail")
    func draftCreationIsSideEffectFree() async throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let revision = scene.snapshot.revision
        let snapshot = CapabilityRegistry.default.exposureSnapshot(
            sceneRevision: revision,
            includedCapabilityIDs: ["scene.set_transform"]
        )
        let contract = try #require(snapshot.contract(id: "scene.set_transform"))
        let input = try JSONSerialization.data(withJSONObject: [
            "entity_id": "scene:\(entity.rawValue)",
            "position": [1, 2, 3],
        ], options: [.sortedKeys])
        let store = CapabilityDraftStore()
        let draft = try await store.createDraft(toolName: contract.toolName,
                                                input: input,
                                                snapshot: snapshot,
                                                currentSceneRevision: revision)
        #expect(scene.snapshot.revision == revision)
        #expect(draft.capabilityID == "scene.set_transform")
        await #expect(throws: CapabilityDraftError.duplicateDraftID(draft.id)) {
            try await store.validatedDrafts(ids: [draft.id, draft.id],
                                            snapshot: snapshot,
                                            currentSceneRevision: revision)
        }
        await #expect(throws: CapabilityDraftError.self) {
            try await store.validatedDrafts(ids: [draft.id],
                                            snapshot: snapshot,
                                            currentSceneRevision: revision + 1)
        }

        var expiredSnapshot = snapshot
        expiredSnapshot.createdAt = Date(timeIntervalSinceNow: -301)
        await #expect(throws: CapabilityDraftError.staleSnapshot) {
            try await store.createDraft(toolName: contract.toolName,
                                        input: input,
                                        snapshot: expiredSnapshot,
                                        currentSceneRevision: revision)
        }
    }

    @Test("optional Codable fields and generated schema agree on null")
    func optionalSchemaDecoderConsistency() throws {
        struct OptionalInput: Codable {
            var required: String
            var optional: String?
        }
        let schema = JSONSchema.object(properties: [
            "required": .string(),
            "optional": .string(),
        ], required: ["required"])
        let data = Data(#"{"required":"value","optional":null}"#.utf8)
        try JSONSchemaValidator.validate(data: data, against: schema)
        let decoded = try JSONDecoder().decode(OptionalInput.self, from: data)
        #expect(decoded.required == "value")
        #expect(decoded.optional == nil)
    }

    @Test("forged tool names cannot create drafts")
    func forgedToolNameFailsClosed() async throws {
        let snapshot = CapabilityRegistry.default.exposureSnapshot(
            sceneRevision: 0,
            includedCapabilityIDs: ["scene.set_name"]
        )
        let input = try JSONSerialization.data(withJSONObject: [
            "entity_id": "scene:1", "name": "Forged",
        ])
        let store = CapabilityDraftStore()
        await #expect(throws: CapabilityDraftError.unknownTool("cap_scene_set_name_v1_forged")) {
            try await store.createDraft(toolName: "cap_scene_set_name_v1_forged",
                                        input: input,
                                        snapshot: snapshot,
                                        currentSceneRevision: 0)
        }
    }

    @Test("AI transactions carry exact invocation records and verification assertions")
    func transactionCarriesExplicitAuthority() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let snapshot = CapabilityRegistry.default.exposureSnapshot(
            sceneRevision: scene.snapshot.revision,
            includedCapabilityIDs: ["scene.set_name"]
        )
        let planData = try JSONSerialization.data(withJSONObject: [
            "summary": "Rename",
            "steps": [[
                "op": "set_name",
                "entity_id": "scene:\(entity.rawValue)",
                "name": "Renamed",
            ]],
        ])
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: planData)
        let transaction = try SceneEditPlanExecutor().buildTransaction(
            from: plan,
            scene: scene,
            baseSceneRevision: scene.snapshot.revision,
            exposureSnapshot: snapshot
        )
        #expect(transaction.capabilityInvocations.count == 1)
        #expect(transaction.capabilityInvocations[0].capabilityID == "scene.set_name")
        #expect(transaction.capabilityInvocations[0].exposureSnapshotID == snapshot.id)
        #expect(transaction.verificationAssertions.contains(
            TransactionVerificationAssertion.entityExists(entity.rawValue)
        ))
    }
}

private final class ResponsesURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func bodyData(from request: URLRequest) -> Data? {
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
    override func startLoading() {
        do {
            let (response, data) = try Self.handler?(request) ?? {
                throw URLError(.badServerResponse)
            }()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class RepairURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var requestCount: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let callNumber = Self.lock.withLock { () -> Int in
                Self.count += 1
                return Self.count
            }
            let responseObject: [String: Any]
            if callNumber == 1 {
                responseObject = ["output": [[
                    "type": "function_call",
                    "call_id": "search_1",
                    "name": CapabilityToolset.searchToolName,
                    "arguments": #"{"query":"rename entity"}"#,
                ]]]
            } else {
                let bodyData = try #require(ResponsesURLProtocol.bodyData(from: request))
                let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
                let tools = try #require(body["tools"] as? [[String: Any]])
                let toolName = try #require(tools.compactMap { $0["name"] as? String }
                    .first { $0.contains("scene_set_name") })
                responseObject = ["output": [[
                    "type": "function_call",
                    "call_id": "invalid_\(callNumber)",
                    "name": toolName,
                    "arguments": #"{"entity_id":"forged","name":"Bad"}"#,
                ]]]
            }
            let data = try JSONSerialization.data(withJSONObject: responseObject)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
