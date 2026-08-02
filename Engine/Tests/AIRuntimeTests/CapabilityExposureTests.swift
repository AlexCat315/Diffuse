import AIRuntime
import CapabilityRuntime
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IntentRuntime
import PluginRuntime
import SceneRuntime
import ScriptRuntime
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
            if descriptor.access.isWrite {
                let registration = try #require(
                    BuiltInTypedCapabilityCatalog.registration(for: operation.capabilityID),
                    "AI write capability \(operation.capabilityID) has no typed preparation"
                )
                #expect(registration.contract == descriptor.contract)
            }
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

    @Test("scene utility writes use typed preparation and preserve shadow state")
    func typedSceneUtilitiesAreAuthoritative() throws {
        var scene = SceneRuntime()
        let parent = scene.createEntity()
        let entity = scene.createEntity()
        _ = scene.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(1, 5, 3)),
            for: entity
        )
        _ = scene.setComponent(RenderMeshComponent(meshIndex: 0), for: entity)
        _ = scene.setComponent(
            AudioSource(clipName: "ambience", volume: 0.25, pitch: 0.8,
                        loop: true, playOnAwake: false, spatialBlend: 0.4),
            for: entity
        )
        _ = scene.setComponent(
            AnimationPlayer(clipName: "Idle", speed: 0.5,
                            loop: true, isPlaying: true),
            for: entity
        )
        _ = scene.setComponent(
            ScriptComponent(bindings: [
                ScriptBinding(ScriptHandle(rawValue: 7),
                              parametersJSON: #"{"existing":1}"#),
            ]),
            for: entity
        )
        let included = [
            "scene.spawn_entity",
            "scene.snap_to_ground",
            "scene.set_mesh_color",
            "scene.set_mesh_visibility",
            "scene.set_audio_source",
            "scene.set_animation_player",
            "scene.set_script_property",
            "scene.set_script_bindings",
        ]
        let snapshot = CapabilityRegistry.aiDefault.exposureSnapshot(
            sceneRevision: scene.snapshot.revision,
            includedCapabilityIDs: Set(included)
        )
        let json = #"""
        {
          "summary":"Typed utilities",
          "steps":[
            {"op":"spawn_entity","label":"Key Light","spawn_kind":"light","spawn_parent_id":"scene:\#(parent.rawValue)","light_type":"spot","intensity":12,"color":[1,0.5,0.25]},
            {"op":"snap_to_ground","entity_id":"scene:\#(entity.rawValue)"},
            {"op":"set_mesh_color","entity_id":"scene:\#(entity.rawValue)","color":[0.2,0.3,0.4]},
            {"op":"set_mesh_visibility","entity_id":"scene:\#(entity.rawValue)","is_visible":false},
            {"op":"set_audio_source","entity_id":"scene:\#(entity.rawValue)","audio_pitch":2},
            {"op":"set_animation_player","entity_id":"scene:\#(entity.rawValue)","animation_is_playing":false},
            {"op":"set_script_property","entity_id":"scene:\#(entity.rawValue)","script_index":0,"script_property_name":"mode","script_property_value":[1,true,"safe"]},
            {"op":"set_script_enabled","entity_id":"scene:\#(entity.rawValue)","script_index":0,"is_enabled":false}
          ]
        }
        """#
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(
            from: plan,
            scene: scene,
            exposureSnapshot: snapshot
        )

        #expect(transaction.operations.count == 8)
        #expect(transaction.capabilityInvocations.map { $0.capabilityID } == included)
        guard transaction.operations.count == 8,
              case let .scene(.spawnLightEntity(label, lightType, _, intensity, color, _, _, parentID))
                = transaction.operations[0],
              case let .scene(.setLocalTransform(_, grounded)) = transaction.operations[1],
              case let .scene(.setAudioSource(_, audio)) = transaction.operations[4],
              case let .scene(.setAnimationPlayer(_, clip, speed, loop, playing))
                = transaction.operations[5],
              case let .scene(.setScriptBindings(_, finalBindings)) = transaction.operations[7]
        else {
            Issue.record("expected typed utility operations")
            return
        }
        #expect(label == "Key Light")
        #expect(lightType == .spot)
        #expect(intensity == 12)
        #expect(color == SIMD3<Float>(1, 0.5, 0.25))
        #expect(parentID == parent.rawValue)
        #expect(grounded.translation == SIMD3<Float>(1, 0, 3))
        #expect(audio.clipName == "ambience")
        #expect(audio.volume == 0.25)
        #expect(audio.pitch == 2)
        #expect(clip == "Idle")
        #expect(speed == 0.5)
        #expect(loop)
        #expect(!playing)
        #expect(finalBindings.count == 1)
        #expect(!finalBindings[0].isEnabled)
        let parameters = try #require(
            JSONSerialization.jsonObject(
                with: Data(finalBindings[0].parametersJSON.utf8)
            ) as? [String: Any]
        )
        #expect(parameters["existing"] as? Int == 1)
        #expect((parameters["mode"] as? [Any])?.count == 3)
        let scriptIndexSchema = try #require(
            SetScriptPropertyCapability.contract.inputSchema.properties["script_index"]
        )
        #expect(scriptIndexSchema.oneOf.first { $0.type == .integer }?.maximum == 255)

        #expect(throws: JSONSchemaViolation.self) {
            try JSONSchemaValidator.validate(
                data: Data(#"{"entity_id":"scene:1","script_property_name":"unsafe","script_property_value":{"arbitrary":true}}"#.utf8),
                against: SetScriptPropertyCapability.contract.inputSchema
            )
        }
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
            .scene(.setLightSpotOuterAngle(entityID: light.rawValue, angleDegrees: 25)),
            .scene(.setLightSpotInnerAngle(entityID: light.rawValue, angleDegrees: 15)),
            .scene(.setLightCastShadows(entityID: light.rawValue, value: true)),
        ])
        #expect(transaction.capabilityInvocations.map(\.capabilityID) == capabilityIDs)
        #expect(transaction.verificationAssertions.contains(
            .sceneState(.lightSpotOuterAngle(entityID: light.rawValue, value: 25))
        ))
        #expect(transaction.verificationAssertions.contains(
            .sceneState(.lightSpotInnerAngle(entityID: light.rawValue, value: 15))
        ))
        var executionContext = TransactionExecutionContext(sceneRuntime: scene)
        _ = try TransactionExecutor().apply(transaction, to: &executionContext)
        #expect(executionContext.sceneRuntime?.component(LightComponent.self, for: light)
            == LightComponent(type: .spot,
                              color: SIMD3<Float>(0.2, 0.4, 0.6),
                              intensity: 250,
                              range: 15,
                              spotInnerAngleDegrees: 15,
                              spotOuterAngleDegrees: 25,
                              castShadows: true))

        let invalidAngleData = try JSONSerialization.data(withJSONObject: [
            "summary": "Invalid spot angle",
            "steps": [[
                "op": "set_light_spot_angles",
                "entity_id": ref,
                "spot_inner_angle": 40,
            ]],
        ])
        let invalidAnglePlan = try JSONDecoder().decode(SceneEditPlan.self,
                                                        from: invalidAngleData)
        #expect(throws: SceneEditPlanExecutorError.self) {
            try SceneEditPlanExecutor().buildTransaction(
                from: invalidAnglePlan,
                scene: scene,
                exposureSnapshot: snapshot
            )
        }

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

    @Test("typed camera capabilities enforce component and geometric constraints")
    func typedCameraCapabilitiesPrepareHostOperations() throws {
        let fovSchema = try #require(
            SetCameraFOVCapability.contract.inputSchema.properties["camera_fov_y"]
        )
        #expect(fovSchema.minimum == 1)
        #expect(fovSchema.maximum == 179)

        var scene = SceneRuntime()
        let camera = scene.createEntity()
        _ = scene.setComponent(CameraComponent(), for: camera)
        let ids: Set<String> = [
            "scene.set_camera_pose",
            "scene.set_camera_fov",
            "scene.set_camera_aspect_ratio",
            "scene.set_camera_active",
        ]
        let snapshot = CapabilityRegistry.aiDefault.exposureSnapshot(
            sceneRevision: scene.snapshot.revision,
            includedCapabilityIDs: ids
        )
        let ref = "scene:\(camera.rawValue)"
        let data = try JSONSerialization.data(withJSONObject: [
            "summary": "Configure camera",
            "steps": [
                ["op": "set_camera_pose", "entity_id": ref,
                 "position": [4, 3, 2], "camera_target": [0, 0, 0],
                 "camera_up": [0, 1, 0]],
                ["op": "set_camera_fov", "entity_id": ref, "camera_fov_y": 70],
                ["op": "set_camera_aspect_ratio", "entity_id": ref,
                 "camera_aspect_ratio": 1.777],
                ["op": "set_camera_active", "entity_id": ref,
                 "camera_is_active": false],
            ],
        ])
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: data)
        let transaction = try SceneEditPlanExecutor().buildTransaction(
            from: plan,
            scene: scene,
            exposureSnapshot: snapshot
        )
        #expect(transaction.operations.count == 4)
        #expect(transaction.capabilityInvocations.map(\.schemaHash) == [
            SetCameraPoseCapability.contract.schemaHash,
            SetCameraFOVCapability.contract.schemaHash,
            SetCameraAspectRatioCapability.contract.schemaHash,
            SetCameraActiveCapability.contract.schemaHash,
        ])
        guard case let .scene(.setCameraPose(_, transform, target, up)) = transaction.operations[0]
        else {
            Issue.record("expected typed setCameraPose operation")
            return
        }
        #expect(transform.translation == SIMD3<Float>(4, 3, 2))
        #expect(target == .zero)
        #expect(up == SIMD3<Float>(0, 1, 0))

        let coincidentData = try JSONSerialization.data(withJSONObject: [
            "summary": "Invalid camera",
            "steps": [["op": "set_camera_pose", "entity_id": ref,
                       "position": [1, 1, 1], "camera_target": [1, 1, 1]]],
        ])
        let coincident = try JSONDecoder().decode(SceneEditPlan.self, from: coincidentData)
        #expect(throws: SceneEditPlanExecutorError.self) {
            try SceneEditPlanExecutor().buildTransaction(
                from: coincident,
                scene: scene,
                exposureSnapshot: snapshot
            )
        }

        let nonCamera = scene.createEntity()
        let wrongTargetData = try JSONSerialization.data(withJSONObject: [
            "summary": "Wrong target",
            "steps": [["op": "set_camera_fov",
                       "entity_id": "scene:\(nonCamera.rawValue)",
                       "camera_fov_y": 60]],
        ])
        let wrongTarget = try JSONDecoder().decode(SceneEditPlan.self, from: wrongTargetData)
        #expect(throws: SceneEditPlanExecutorError.self) {
            try SceneEditPlanExecutor().buildTransaction(
                from: wrongTarget,
                scene: scene,
                exposureSnapshot: snapshot
            )
        }
    }

    @Test("typed material capability preserves omitted fields in sequential preparation")
    func typedMaterialUsesValueOnlyShadowState() throws {
        let baseColorSchema = try #require(
            SetMaterialCapability.contract.inputSchema.properties["material_base_color"]
        )
        let baseColorArray = try #require(baseColorSchema.oneOf.first { $0.type == .array })
        #expect(baseColorArray.items.first?.minimum == 0)
        #expect(baseColorArray.items.first?.maximum == 1)

        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(
            RenderMaterialComponent(
                baseColorFactor: SIMD4<Float>(0.2, 0.4, 0.6, 1),
                metallicFactor: 0.3,
                roughnessFactor: 0.8,
                emissiveFactor: SIMD3<Float>(0.1, 0.2, 0.3)
            ),
            for: entity
        )
        let snapshot = CapabilityRegistry.aiDefault.exposureSnapshot(
            sceneRevision: scene.snapshot.revision,
            includedCapabilityIDs: ["scene.set_material"]
        )
        let ref = "scene:\(entity.rawValue)"
        let data = try JSONSerialization.data(withJSONObject: [
            "summary": "Update material",
            "steps": [
                ["op": "set_material", "entity_id": ref, "material_roughness": 0.2],
                ["op": "set_material", "entity_id": ref, "material_metallic": 0.9],
            ],
        ])
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: data)
        let transaction = try SceneEditPlanExecutor().buildTransaction(
            from: plan,
            scene: scene,
            exposureSnapshot: snapshot
        )
        guard transaction.operations.count == 2,
              case let .scene(.setRenderMaterialComponent(_, base, _, _, metallic, roughness, emissive))
                = transaction.operations[1] else {
            Issue.record("expected a second typed material operation")
            return
        }
        #expect(base == SIMD4<Float>(0.2, 0.4, 0.6, 1))
        #expect(abs(metallic - 0.9) < 0.001)
        #expect(abs(roughness - 0.2) < 0.001)
        #expect(emissive == SIMD3<Float>(0.1, 0.2, 0.3))

        let emptyData = try JSONSerialization.data(withJSONObject: [
            "summary": "No-op material",
            "steps": [["op": "set_material", "entity_id": ref]],
        ])
        let emptyPlan = try JSONDecoder().decode(SceneEditPlan.self, from: emptyData)
        #expect(throws: SceneEditPlanExecutorError.self) {
            try SceneEditPlanExecutor().buildTransaction(
                from: emptyPlan,
                scene: scene,
                exposureSnapshot: snapshot
            )
        }
    }

    @Test("typed physics capabilities are beta-gated and preserve multi-step component state")
    func typedPhysicsCapabilitiesUseSequentialCopies() throws {
        let physicsIDs: Set<String> = [
            "scene.set_rigid_body_motion_type",
            "scene.set_rigid_body_mass",
            "scene.set_rigid_body_gravity_scale",
            "scene.set_rigid_body_allow_sleep",
            "scene.set_collider_shape",
            "scene.set_collider_box_extents",
            "scene.set_collider_sphere_radius",
            "scene.set_collider_capsule",
            "scene.set_collider_material",
            "scene.set_collider_trigger",
            "scene.set_collider_layer",
        ]
        let migratedIDs = Set(BuiltInTypedCapabilityCatalog.registrations.map(\.contract.id))
        #expect(physicsIDs.isSubset(of: migratedIDs))
        let stableSnapshot = CapabilityRegistry.aiDefault.exposureSnapshot(
            includedCapabilityIDs: physicsIDs
        )
        #expect(stableSnapshot.contracts.isEmpty)

        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let snapshot = CapabilityRegistry.aiDefault.exposureSnapshot(
            policy: CapabilityExposurePolicy(activeReleasePhase: .beta,
                                             maximumCapabilities: 32),
            sceneRevision: scene.snapshot.revision,
            includedCapabilityIDs: physicsIDs
        )
        #expect(Set(snapshot.contracts.map(\.id)) == physicsIDs)
        let ref = "scene:\(entity.rawValue)"
        let data = try JSONSerialization.data(withJSONObject: [
            "summary": "Configure physics",
            "steps": [
                ["op": "set_rigidbody_motion", "entity_id": ref,
                 "motion_type": "kinematic"],
                ["op": "set_rigidbody_mass", "entity_id": ref, "mass": 12],
                ["op": "set_collider_trigger", "entity_id": ref, "is_trigger": true],
                ["op": "set_collider_sphere_radius", "entity_id": ref, "radius": 2],
            ],
        ])
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: data)
        let transaction = try SceneEditPlanExecutor().buildTransaction(
            from: plan,
            scene: scene,
            exposureSnapshot: snapshot
        )
        #expect(transaction.operations.count == 4)
        guard case let .scene(.setRigidBody(_, body)) = transaction.operations[1] else {
            Issue.record("expected typed rigid body replacement")
            return
        }
        #expect(body.motionType == .kinematic)
        #expect(abs(body.mass - 12) < 0.001)
        guard case let .scene(.setCollider(_, collider)) = transaction.operations[3] else {
            Issue.record("expected typed collider replacement")
            return
        }
        #expect(collider.isTrigger)
        if case let .sphere(radius, _) = collider.shape {
            #expect(abs(radius - 2) < 0.001)
        } else {
            Issue.record("expected the sequential collider state to be a sphere")
        }
        var executionContext = TransactionExecutionContext(sceneRuntime: scene)
        _ = try TransactionExecutor().apply(transaction, to: &executionContext)
        #expect(executionContext.sceneRuntime?.component(RigidBody.self, for: entity)?.motionType
                == .kinematic)
        #expect(executionContext.sceneRuntime?.component(RigidBody.self, for: entity)?.mass == 12)
        #expect(executionContext.sceneRuntime?.component(Collider.self, for: entity)?.isTrigger
                == true)
        if case let .sphere(radius, _)? = executionContext.sceneRuntime?
            .component(Collider.self, for: entity)?.shape {
            #expect(radius == 2)
        } else {
            Issue.record("expected verified sphere collider state")
        }

        #expect(throws: JSONSchemaViolation.self) {
            try JSONSchemaValidator.validate(
                data: Data(#"{"entity_id":"scene:1","mass":0}"#.utf8),
                against: SetRigidBodyMassCapability.contract.inputSchema
            )
        }
        let noFieldsData = try JSONSerialization.data(withJSONObject: [
            "summary": "Invalid material",
            "steps": [["op": "set_collider_material", "entity_id": ref]],
        ])
        let noFields = try JSONDecoder().decode(SceneEditPlan.self, from: noFieldsData)
        #expect(throws: SceneEditPlanExecutorError.self) {
            try SceneEditPlanExecutor().buildTransaction(
                from: noFields,
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

    @Test("plugin writes expand into host primitives with exact authority records")
    func pluginWriteUsesUnifiedDraftAndTransactionPipeline() async throws {
        let setup = try makePluginBinding(
            pluginID: "safe.layout",
            capabilityName: "rename-selected",
            access: .reversibleWrite,
            composableHostCapabilities: ["scene.set_name"],
            hostGeneration: 7
        )
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let revision = scene.snapshot.revision
        let hostArguments = Data(
            #"{"entity_id":"scene:\#(entity.rawValue)","name":"Plugin Rename"}"#.utf8
        )
        let invoker = StubPluginInvoker(
            generation: 7,
            result: .hostCalls([
                HostCapabilityCall(capabilityID: "scene.set_name",
                                   version: 1,
                                   arguments: hostArguments),
            ])
        )
        let executor = try PluginCapabilityExecutor(bindings: [setup.binding],
                                                    invoker: invoker)
        let sessions = CapabilityExposureSessionStore(
            registry: executor.registry,
            exposurePolicy: executor.exposurePolicy,
            pluginAuthorities: executor.pluginAuthorities
        )
        let sessionID = UUID().uuidString
        let activation = try await sessions.search(sessionID: sessionID,
                                                   query: "rename",
                                                   domain: "plugin",
                                                   sceneRevision: revision)
        let contract = try #require(activation.contracts.first {
            $0.id == setup.contract.id
        })
        let draft = try await sessions.createDraft(
            sessionID: sessionID,
            toolName: contract.toolName,
            input: Data(#"{"entity_id":"scene:\#(entity.rawValue)"}"#.utf8),
            sceneRevision: revision
        )
        #expect(draft.pluginAuthority == setup.binding.authority)
        let validated = try await sessions.validatedDrafts(sessionID: sessionID,
                                                           ids: [draft.id],
                                                           sceneRevision: revision)

        let transaction = try executor.buildTransaction(
            summary: "Plugin rename",
            drafts: validated.drafts,
            snapshot: validated.snapshot,
            scene: scene,
            currentSceneRevision: revision
        )
        #expect(transaction.operations == [
            .scene(.setSceneName(entityID: entity.rawValue, value: "Plugin Rename")),
        ])
        #expect(transaction.capabilityInvocations.map(\.capabilityID) == [
            setup.contract.id, "scene.set_name",
        ])
        #expect(transaction.capabilityInvocations[0].sourcePluginID == "safe.layout")
        #expect(transaction.capabilityInvocations[0].pluginAuthority == setup.binding.authority)
        #expect(transaction.capabilityInvocations[1].sourcePluginID == nil)
        #expect(transaction.verificationAssertions.contains(.entityExists(entity.rawValue)))

        let planner = executor.makeInvocationPlanner()
        let planned = try planner.plan(transaction: transaction,
                                       context: CapabilityInvocationContext(sceneRuntime: scene))
        #expect(planned.approvalPolicy == .requiresApproval)

        invoker.setGeneration(8)
        #expect(throws: CapabilityInvocationPlannerError.self) {
            try planner.plan(transaction: transaction,
                             context: CapabilityInvocationContext(sceneRuntime: scene))
        }
        #expect(throws: PluginCapabilityExecutorError.authorityChanged("safe.layout")) {
            try executor.buildTransaction(summary: "Stale",
                                          drafts: validated.drafts,
                                          snapshot: validated.snapshot,
                                          scene: scene,
                                          currentSceneRevision: revision)
        }

        await sessions.replacePluginAuthorities(
            ["safe.layout": PluginCapabilityAuthority(
                pluginID: "safe.layout",
                authorizationDigest: setup.binding.authorization.authorityDigest,
                hostGeneration: 8
            )],
            enabledPluginIDs: ["safe.layout"]
        )
        await #expect(throws: CapabilityExposureSessionError.sessionNotFound) {
            try await sessions.validatedDrafts(sessionID: sessionID,
                                               ids: [draft.id],
                                               sceneRevision: revision)
        }
    }

    @Test("plugin reads execute immediately and never become Drafts")
    func pluginReadIsImmediateBoundedContext() throws {
        let setup = try makePluginBinding(pluginID: "safe.reader",
                                          capabilityName: "inspect",
                                          access: .read,
                                          hostGeneration: 3)
        let invoker = StubPluginInvoker(
            generation: 3,
            result: .read(Data(#"{"finding":"ok"}"#.utf8))
        )
        let executor = try PluginCapabilityExecutor(bindings: [setup.binding],
                                                    invoker: invoker)
        let revision: UInt64 = 41
        let snapshot = executor.registry.exposureSnapshot(
            policy: executor.exposurePolicy,
            sceneRevision: revision,
            includedCapabilityIDs: [setup.contract.id],
            pluginAuthorities: executor.pluginAuthorities
        )
        let output = try executor.executeRead(
            toolName: setup.contract.toolName,
            input: Data(#"{"entity_id":"scene:1"}"#.utf8),
            snapshot: snapshot,
            currentSceneRevision: revision
        )
        #expect(output == Data(#"{"finding":"ok"}"#.utf8))

        let invalidInvoker = StubPluginInvoker(generation: 3,
                                               result: .read(Data("not-json".utf8)))
        let invalidExecutor = try PluginCapabilityExecutor(bindings: [setup.binding],
                                                           invoker: invalidInvoker)
        #expect(throws: PluginCapabilityExecutorError.invalidReadResult(setup.contract.id)) {
            try invalidExecutor.executeRead(toolName: setup.contract.toolName,
                                            input: Data(#"{"entity_id":"scene:1"}"#.utf8),
                                            snapshot: snapshot,
                                            currentSceneRevision: revision)
        }
    }

    @Test("dynamic Registry replacement destroys old sessions before exposing plugins")
    func dynamicRegistryReplacementInvalidatesDrafts() async throws {
        let sessions = CapabilityExposureSessionStore()
        let sessionID = UUID().uuidString
        let activation = try await sessions.search(sessionID: sessionID,
                                                   query: "rename",
                                                   sceneRevision: 12)
        let rename = try #require(activation.contracts.first { $0.id == "scene.set_name" })
        let oldDraft = try await sessions.createDraft(
            sessionID: sessionID,
            toolName: rename.toolName,
            input: Data(#"{"entity_id":"scene:1","name":"Old"}"#.utf8),
            sceneRevision: 12
        )

        let setup = try makePluginBinding(pluginID: "safe.dynamic",
                                          capabilityName: "arrange",
                                          access: .reversibleWrite,
                                          composableHostCapabilities: ["scene.set_name"],
                                          hostGeneration: 4)
        let invoker = StubPluginInvoker(
            generation: 4,
            result: .hostCalls([
                HostCapabilityCall(capabilityID: "scene.set_name",
                                   version: 1,
                                   arguments: Data(#"{"entity_id":"scene:1","name":"New"}"#.utf8)),
            ])
        )
        let executor = try PluginCapabilityExecutor(bindings: [setup.binding],
                                                    invoker: invoker)
        await sessions.replaceRegistry(executor.registry,
                                       exposurePolicy: executor.exposurePolicy,
                                       pluginAuthorities: executor.pluginAuthorities)
        await #expect(throws: CapabilityExposureSessionError.sessionNotFound) {
            try await sessions.validatedDrafts(sessionID: sessionID,
                                               ids: [oldDraft.id],
                                               sceneRevision: 12)
        }

        let pluginActivation = try await sessions.search(sessionID: sessionID,
                                                         query: "arrange",
                                                         domain: "plugin",
                                                         sceneRevision: 12)
        #expect(pluginActivation.contracts.map(\.id) == [setup.contract.id])
        let snapshot = try await sessions.snapshot(sessionID: sessionID,
                                                   sceneRevision: 12)
        #expect(snapshot.authority(forPluginID: "safe.dynamic") == setup.binding.authority)
    }

    @Test("Session keeps plugin writes as authority-bound Drafts for Editor transaction preparation")
    func sessionReturnsPluginDraftProposal() async throws {
        PluginSessionURLProtocol.reset()
        let setup = try makePluginBinding(pluginID: "safe.session",
                                          capabilityName: "arrange",
                                          access: .reversibleWrite,
                                          composableHostCapabilities: ["scene.set_name"],
                                          hostGeneration: 5)
        let invoker = StubPluginInvoker(
            generation: 5,
            result: .hostCalls([
                HostCapabilityCall(capabilityID: "scene.set_name",
                                   version: 1,
                                   arguments: Data(#"{"entity_id":"scene:1","name":"Arranged"}"#.utf8)),
            ])
        )
        let executor = try PluginCapabilityExecutor(bindings: [setup.binding],
                                                    invoker: invoker)
        PluginSessionURLProtocol.pluginToolName = setup.contract.toolName
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PluginSessionURLProtocol.self]
        let session = Session(
            config: .openAIResponses(apiKey: "test"),
            urlSession: URLSession(configuration: configuration),
            pluginCapabilityExecutor: executor
        )

        let proposal = try await session.process(
            .naturalLanguage(text: "Arrange with the plugin", locale: "en")
        )
        #expect(proposal.plan.summary == "Arrange selection")
        #expect(proposal.plan.steps.isEmpty)
        #expect(proposal.capabilityDrafts.count == 1)
        #expect(proposal.capabilityDrafts.first?.capabilityID == setup.contract.id)
        #expect(proposal.capabilityDrafts.first?.pluginAuthority == setup.binding.authority)
        #expect(proposal.capabilityExposureSnapshot?.authority(forPluginID: "safe.session")
                == setup.binding.authority)
        #expect(PluginSessionURLProtocol.requestCount == 3)
    }
}

private func makePluginBinding(
    pluginID: String,
    capabilityName: String,
    access: CapabilityAccess,
    composableHostCapabilities: [String] = [],
    hostGeneration: UInt64
) throws -> (binding: PluginExecutionBinding, contract: CapabilityContract) {
    let manifest = GuavaPluginManifest(
        id: pluginID,
        version: 1,
        name: "Test plugin",
        description: "Bounded test plugin",
        access: access,
        composableHostCapabilities: composableHostCapabilities
    )
    let contract = CapabilityContract(
        id: "\(pluginID).\(capabilityName)",
        title: "Test Capability",
        description: "Test WIT-derived capability",
        domain: "plugin",
        access: access,
        releasePhase: .stable,
        inputSchema: .object(
            properties: ["entity_id": .string()],
            required: ["entity_id"]
        ),
        source: .plugin(pluginID)
    )
    let inspection = PluginInspection(manifest: manifest,
                                      componentHash: "component-hash",
                                      witHash: "wit-hash",
                                      contracts: [contract])
    let authorization = try PluginAuthorizationRecord(
        inspection: inspection,
        authorisedAt: Date(timeIntervalSince1970: 1)
    )
    let pluginPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(pluginID).guavaplugin", isDirectory: true)
        .path
    return (try PluginExecutionBinding(pluginPath: pluginPath,
                                       inspection: inspection,
                                       authorization: authorization,
                                       hostGeneration: hostGeneration),
            contract)
}

private final class StubPluginInvoker: PluginCapabilityInvoking, @unchecked Sendable {
    private let lock = NSLock()
    private var storedGeneration: UInt64
    private let result: PluginPreparedCapabilityResult

    var generation: UInt64 { lock.withLock { storedGeneration } }

    init(generation: UInt64, result: PluginPreparedCapabilityResult) {
        storedGeneration = generation
        self.result = result
    }

    func setGeneration(_ generation: UInt64) {
        lock.withLock { storedGeneration = generation }
    }

    func prepareCapability(binding: PluginExecutionBinding,
                           capabilityID: String,
                           input: Data,
                           querySnapshot: PluginQuerySnapshot?) throws
        -> PluginPreparedCapabilityResult {
        result
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

private final class PluginSessionURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) static var pluginToolName = ""
    static var requestCount: Int { lock.withLock { count } }

    static func reset() {
        lock.withLock { count = 0 }
        pluginToolName = ""
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let callNumber = Self.lock.withLock { () -> Int in
                Self.count += 1
                return Self.count
            }
            let bodyData = try #require(ResponsesURLProtocol.bodyData(from: request))
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            let responseObject: [String: Any]
            switch callNumber {
            case 1:
                responseObject = ["output": [[
                    "type": "function_call",
                    "call_id": "plugin_search",
                    "name": CapabilityToolset.searchToolName,
                    "arguments": #"{"query":"arrange","domain":"plugin"}"#,
                ]]]
            case 2:
                let tools = try #require(body["tools"] as? [[String: Any]])
                #expect(tools.contains { $0["name"] as? String == Self.pluginToolName })
                responseObject = ["output": [[
                    "type": "function_call",
                    "call_id": "plugin_draft",
                    "name": Self.pluginToolName,
                    "arguments": #"{"entity_id":"scene:1"}"#,
                ]]]
            default:
                let inputs = try #require(body["input"] as? [[String: Any]])
                let draftID = try #require(inputs.reversed().compactMap { item -> String? in
                    guard item["type"] as? String == "function_call_output",
                          let output = item["output"] as? String,
                          let data = output.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { return nil }
                    return object["draft_id"] as? String
                }.first)
                responseObject = ["output": [[
                    "type": "function_call",
                    "call_id": "plugin_submit",
                    "name": CapabilityToolset.submitToolName,
                    "arguments": #"{"summary":"Arrange selection","draft_ids":["\#(draftID)"]}"#,
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
