import AIRuntime
import CapabilityRuntime
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IntentRuntime
import SceneRuntime
import SIMDCompat
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
                CapabilityRegistry.aiDefault.descriptor(for: operation.capabilityID),
                "missing capability for \(operation.rawValue)"
            )
            #expect(descriptor.isAIExposed)
            #expect(descriptor.contract.inputSchema.additionalProperties == false)
            #expect(!descriptor.access.isWrite || descriptor.contract.inputSchema.isStrictCapabilityInput)
            #expect(!descriptor.contract.schemaHash.isEmpty)
        }
        try CapabilityRegistry.aiDefault.validateIntegrity()
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
        let snapshot = CapabilityRegistry.aiDefault.exposureSnapshot(
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
        let snapshot = CapabilityRegistry.aiDefault.exposureSnapshot(
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

    @Test("session capability searches expand one snapshot without invalidating earlier drafts")
    func exposureSessionExpansionPreservesDraftAuthority() async throws {
        let sessionID = UUID().uuidString
        let sessions = CapabilityExposureSessionStore()
        let first = try await sessions.search(sessionID: sessionID,
                                              query: "rename entity",
                                              sceneRevision: 9)
        let rename = try #require(first.contracts.first { $0.id == "scene.set_name" })
        let draft = try await sessions.createDraft(
            sessionID: sessionID,
            toolName: rename.toolName,
            input: Data(#"{"entity_id":"scene:1","name":"Renamed"}"#.utf8),
            sceneRevision: 9
        )

        let second = try await sessions.search(sessionID: sessionID,
                                               query: "transform",
                                               sceneRevision: 9)
        #expect(second.snapshotID == first.snapshotID)
        #expect(second.contracts.contains { $0.id == "scene.set_transform" })
        let submitted = try await sessions.validatedDrafts(sessionID: sessionID,
                                                           ids: [draft.id],
                                                           sceneRevision: 9)
        #expect(submitted.drafts == [draft])
        #expect(submitted.snapshot.id == first.snapshotID)

        _ = try await sessions.search(sessionID: sessionID,
                                      query: "rename",
                                      sceneRevision: 10)
        await #expect(throws: CapabilityDraftError.self) {
            try await sessions.validatedDrafts(sessionID: sessionID,
                                               ids: [draft.id],
                                               sceneRevision: 10)
        }
    }

    @Test("transport sessions begin with only core reads and never exceed the active tool cap")
    func exposureSessionBootstrapIsBounded() async throws {
        let sessionID = UUID().uuidString
        let sessions = CapabilityExposureSessionStore()
        let initial = try await sessions.bootstrap(sessionID: sessionID, sceneRevision: 4)
        #expect(Set(initial.contracts.map(\.id)) == [
            "scene.get_entities", "scene.get_selection", "scene.find_entities",
        ])
        #expect(initial.contracts.allSatisfy { $0.access == .read })

        let expanded = try await sessions.search(sessionID: sessionID,
                                                 query: "scene",
                                                 sceneRevision: 4)
        #expect(expanded.snapshotID == initial.snapshotID)
        #expect(expanded.activeContracts.count <= CapabilityExposureSessionStore.maximumActiveCapabilities)
        #expect(expanded.activeToolCount == expanded.activeContracts.count)
        #expect(Set(initial.contracts.map(\.id)).isSubset(of: Set(expanded.activeContracts.map(\.id))))

        await #expect(throws: CapabilityDraftError.unknownTool("cap_scene_set_name_v1_forged")) {
            try await sessions.contract(sessionID: sessionID,
                                        toolName: "cap_scene_set_name_v1_forged",
                                        sceneRevision: 4)
        }
    }

    @Test("migrated primitives expose and execute their generated typed contract")
    func typedBuiltInPrimitiveIsAuthoritative() throws {
        for registration in BuiltInTypedCapabilityCatalog.registrations {
            let exposed = try #require(
                CapabilityRegistry.aiDefault.descriptor(for: registration.contract.id)?.contract
            )
            #expect(exposed == registration.contract)
            #expect(exposed.inputSchema.additionalProperties == false)
        }
        #expect(SetNameCapability.contract.inputSchema.properties["name"]?.minimumLength == 1)
        #expect(SetNameCapability.contract.inputSchema.properties["name"]?.maximumLength == 256)
        #expect(throws: JSONSchemaViolation.self) {
            try JSONSchemaValidator.validate(
                data: Data(#"{"entity_id":"scene:1","name":""}"#.utf8),
                against: SetNameCapability.contract.inputSchema
            )
        }

        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let snapshot = CapabilityRegistry.aiDefault.exposureSnapshot(
            sceneRevision: scene.snapshot.revision,
            includedCapabilityIDs: ["scene.set_name"]
        )
        let plan = try JSONDecoder().decode(
            SceneEditPlan.self,
            from: Data(#"{"summary":"Rename","steps":[{"op":"set_name","entity_id":"scene:\#(entity.rawValue)","name":"Typed"}]}"#.utf8)
        )
        let transaction = try SceneEditPlanExecutor().buildTransaction(
            from: plan,
            scene: scene,
            exposureSnapshot: snapshot
        )
        #expect(transaction.operations == [
            .scene(.setSceneName(entityID: entity.rawValue, value: "Typed")),
        ])
        #expect(transaction.capabilityInvocations.first?.schemaHash
                == SetNameCapability.contract.schemaHash)
    }

    @Test("typed transform preparation preserves omitted fields across the shadow scene")
    func typedTransformUsesValueOnlyShadowState() throws {
        let contract = SetTransformCapability.contract
        #expect(contract.inputSchema.additionalProperties == false)
        #expect(contract.inputSchema.required == ["entity_id"])
        let scaleSchema = try #require(contract.inputSchema.properties["scale"])
        let scaleArray = try #require(scaleSchema.oneOf.first { $0.type == .array })
        #expect(scaleArray.items.first?.minimum == 0.001)
        #expect(scaleArray.items.first?.maximum == 1_000)

        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(1, 2, 3)),
            for: entity
        )
        let snapshot = CapabilityRegistry.aiDefault.exposureSnapshot(
            sceneRevision: scene.snapshot.revision,
            includedCapabilityIDs: ["scene.set_transform"]
        )
        let json = #"{"summary":"Transform","steps":[{"op":"set_transform","entity_id":"scene:\#(entity.rawValue)","position":[10,20,30]},{"op":"set_transform","entity_id":"scene:\#(entity.rawValue)","scale":[2,3,4]}]}"#
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(
            from: plan,
            scene: scene,
            exposureSnapshot: snapshot
        )
        #expect(transaction.operations.count == 2)
        guard transaction.operations.count == 2,
              case let .scene(.setLocalTransform(_, secondTransform)) = transaction.operations[1] else {
            Issue.record("expected a second typed setLocalTransform operation")
            return
        }
        #expect(secondTransform.translation == SIMD3<Float>(10, 20, 30))
        #expect(length(SIMD3(
            secondTransform.matrix.columns.0.x,
            secondTransform.matrix.columns.0.y,
            secondTransform.matrix.columns.0.z
        )) == 2)
        #expect(length(SIMD3(
            secondTransform.matrix.columns.1.x,
            secondTransform.matrix.columns.1.y,
            secondTransform.matrix.columns.1.z
        )) == 3)
        #expect(length(SIMD3(
            secondTransform.matrix.columns.2.x,
            secondTransform.matrix.columns.2.y,
            secondTransform.matrix.columns.2.z
        )) == 4)
        #expect(transaction.capabilityInvocations.allSatisfy {
            $0.schemaHash == SetTransformCapability.contract.schemaHash
        })

        #expect(throws: JSONSchemaViolation.self) {
            try JSONSchemaValidator.validate(
                data: Data(#"{"entity_id":"scene:1","scale":[0,1,1]}"#.utf8),
                against: contract.inputSchema
            )
        }
        let emptyTransformJSON = #"{"summary":"No-op","steps":[{"op":"set_transform","entity_id":"scene:\#(entity.rawValue)"}]}"#
        let emptyTransformPlan = try JSONDecoder().decode(
            SceneEditPlan.self,
            from: Data(emptyTransformJSON.utf8)
        )
        #expect(throws: SceneEditPlanExecutorError.self) {
            try SceneEditPlanExecutor().buildTransaction(
                from: emptyTransformPlan,
                scene: scene,
                exposureSnapshot: snapshot
            )
        }
    }

    @Test("typed light capabilities validate components and generate host operations")
    func typedLightCapabilitiesPrepareHostOperations() throws {
        let typeSchema = try #require(
            SetLightTypeCapability.contract.inputSchema.properties["light_type"]
        )
        #expect(typeSchema.allowedValues == [
            .string("directional"), .string("point"), .string("spot"),
        ])
        let colorSchema = try #require(
            SetLightColorCapability.contract.inputSchema.properties["color"]
        )
        #expect(colorSchema.items.first?.minimum == 0)
        #expect(colorSchema.items.first?.maximum == 1)

        var scene = SceneRuntime()
        let light = scene.createEntity()
        _ = scene.setComponent(LightComponent(type: .point), for: light)
        let capabilityIDs = [
            "scene.set_light_type",
            "scene.set_light_intensity",
            "scene.set_light_color",
            "scene.set_light_range",
            "scene.set_light_spot_angles",
            "scene.set_light_cast_shadows",
        ]
        let snapshot = CapabilityRegistry.aiDefault.exposureSnapshot(
            sceneRevision: scene.snapshot.revision,
            includedCapabilityIDs: Set(capabilityIDs)
        )
        let ref = "scene:\(light.rawValue)"
        let planData = try JSONSerialization.data(withJSONObject: [
            "summary": "Configure light",
            "steps": [
                ["op": "set_light_type", "entity_id": ref, "light_type": "spot"],
                ["op": "set_light_intensity", "entity_id": ref, "intensity": 250],
                ["op": "set_light_color", "entity_id": ref, "color": [0.2, 0.4, 0.6]],
                ["op": "set_light_range", "entity_id": ref, "range": 15],
                ["op": "set_light_spot_angles", "entity_id": ref,
                 "spot_inner_angle": 15, "spot_outer_angle": 25],
                ["op": "set_light_cast_shadows", "entity_id": ref,
                 "light_cast_shadows": true],
            ],
        ])
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: planData)
        let transaction = try SceneEditPlanExecutor().buildTransaction(
            from: plan,
            scene: scene,
            exposureSnapshot: snapshot
        )
        #expect(transaction.operations == [
            .scene(.setLightType(entityID: light.rawValue, type: .spot)),
            .scene(.setLightIntensity(entityID: light.rawValue, intensity: 250)),
            .scene(.setLightColor(entityID: light.rawValue, color: SIMD3<Float>(0.2, 0.4, 0.6))),
            .scene(.setLightRange(entityID: light.rawValue, range: 15)),
            .scene(.setLightSpotInnerAngle(entityID: light.rawValue, angleDegrees: 15)),
            .scene(.setLightSpotOuterAngle(entityID: light.rawValue, angleDegrees: 25)),
            .scene(.setLightCastShadows(entityID: light.rawValue, value: true)),
        ])
        #expect(transaction.capabilityInvocations.map(\.capabilityID) == capabilityIDs)

        let nonLight = scene.createEntity()
        let invalidData = try JSONSerialization.data(withJSONObject: [
            "summary": "Invalid target",
            "steps": [[
                "op": "set_light_intensity",
                "entity_id": "scene:\(nonLight.rawValue)",
                "intensity": 1,
            ]],
        ])
        let invalidPlan = try JSONDecoder().decode(SceneEditPlan.self, from: invalidData)
        #expect(throws: SceneEditPlanExecutorError.self) {
            try SceneEditPlanExecutor().buildTransaction(
                from: invalidPlan,
                scene: scene,
                exposureSnapshot: snapshot
            )
        }

        let invalidAnglesData = try JSONSerialization.data(withJSONObject: [
            "summary": "Invalid angles",
            "steps": [[
                "op": "set_light_spot_angles",
                "entity_id": ref,
                "spot_inner_angle": 60,
                "spot_outer_angle": 30,
            ]],
        ])
        let invalidAnglesPlan = try JSONDecoder().decode(
            SceneEditPlan.self,
            from: invalidAnglesData
        )
        #expect(throws: SceneEditPlanExecutorError.self) {
            try SceneEditPlanExecutor().buildTransaction(
                from: invalidAnglesPlan,
                scene: scene,
                exposureSnapshot: snapshot
            )
        }
    }

    @Test("shadow preparation rejects a later typed call to an entity deleted earlier")
    func typedPreparationUsesSequentialShadowScene() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let snapshot = CapabilityRegistry.aiDefault.exposureSnapshot(
            sceneRevision: scene.snapshot.revision,
            includedCapabilityIDs: ["scene.delete_entity", "scene.set_name"]
        )
        let json = #"{"summary":"Invalid sequence","steps":[{"op":"delete_entity","entity_id":"scene:\#(entity.rawValue)"},{"op":"set_name","entity_id":"scene:\#(entity.rawValue)","name":"Too late"}]}"#
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        #expect(throws: SceneEditPlanExecutorError.self) {
            try SceneEditPlanExecutor().buildTransaction(
                from: plan,
                scene: scene,
                exposureSnapshot: snapshot
            )
        }
    }

    @Test("AI transactions carry exact invocation records and verification assertions")
    func transactionCarriesExplicitAuthority() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let snapshot = CapabilityRegistry.aiDefault.exposureSnapshot(
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
