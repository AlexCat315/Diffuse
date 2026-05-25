@testable import AIRuntime
import ContextMemory
import IntentRuntime
import PerceptionRuntime
import SceneRuntime
import simd
import XCTest

final class AIRuntimeTests: XCTestCase {
    func testWorldViewStoresInferredSourceFromWorldEvent() {
        var worldView = WorldView()
        worldView.apply(event: .entityAdded(ref: "scene:1", name: "Hero", kind: "mesh"))
        worldView.apply(event: .entityInferredUpdated(ref: "scene:1",
                                                      property: "object_category",
                                                      value: .string("chair"),
                                                      confidence: 0.91,
                                                      source: "perception:fixture_classifier"))

        let inferred = worldView.entityIndex["scene:1"]?.inferred["object_category"]
        XCTAssertEqual(inferred?.displayValue, "chair")
        XCTAssertEqual(inferred?.confidence, 0.91)
        XCTAssertEqual(inferred?.source, "perception:fixture_classifier")
    }

    func testAIWorldContextStoresInferredEventsWithoutRemoteSession() async {
        let context = AIWorldContext()
        await context.observe(events: [
            .entityAdded(ref: "scene:1", name: "Hero", kind: "mesh"),
            .entityInferredUpdated(ref: "scene:1",
                                   property: "object_category",
                                   value: .string("trashcan"),
                                   confidence: 0.84,
                                   source: "perception:apple_vision_classify_image_v1"),
        ])

        let record = await context.entityRecord(ref: "scene:1")
        XCTAssertEqual(record?.name, "Hero")
        XCTAssertEqual(record?.inferred["object_category"]?.displayValue, "trashcan")
        XCTAssertEqual(record?.inferred["object_category"]?.source, "perception:apple_vision_classify_image_v1")
    }

    func testSnapshotEulerDegreesCopiedToEntityRecord() {
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:9",
            name: "TiltedBox",
            kind: "mesh",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [0, 0, 0],
            eulerDegrees: [45, 0, 30],
            components: ["transform", "mesh"]
        )
        var worldView = WorldView()
        worldView.apply(snapshot: SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity]))

        XCTAssertEqual(worldView.entityIndex["scene:9"]?.eulerDegrees, [45, 0, 30])
    }

    func testSnapshotScaleCopiedToEntityRecord() {
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:7",
            name: "BigBox",
            kind: "mesh",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [0, 0, 0],
            scale: [2, 3, 0.5],
            components: ["transform", "mesh"]
        )
        var worldView = WorldView()
        worldView.apply(snapshot: SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity]))

        XCTAssertEqual(worldView.entityIndex["scene:7"]?.scale, [2, 3, 0.5])
    }

    func testEntityAuthoredScaleEventPopulatesRecord() {
        var worldView = WorldView()
        worldView.apply(event: .entityAdded(ref: "scene:8", name: "Crate", kind: "mesh"))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:8", property: "scale", value: .vec3(2, 2, 2)))

        XCTAssertEqual(worldView.entityIndex["scene:8"]?.scale, [2, 2, 2])
    }

    func testSnapshotWorldPositionPopulatesEvaluatedDict() {
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:1",
            name: "Hero",
            kind: "mesh",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [0, 0, 0],
            worldPosition: [3, 4, 5],
            components: ["transform", "mesh"]
        )
        let snapshot = SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity])
        var worldView = WorldView()
        worldView.apply(snapshot: snapshot)

        XCTAssertEqual(
            worldView.entityIndex["scene:1"]?.evaluated["worldPosition"],
            .vec3(3, 4, 5)
        )
    }

    func testSnapshotWithoutWorldPositionLeavesEvaluatedEmpty() {
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:2",
            name: "Root",
            kind: "group",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [1, 2, 3],
            worldPosition: nil,
            components: ["transform"]
        )
        let snapshot = SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity])
        var worldView = WorldView()
        worldView.apply(snapshot: snapshot)

        XCTAssertNil(worldView.entityIndex["scene:2"]?.evaluated["worldPosition"])
    }

    func testSnapshotPhysicsColliderAudioFieldsCopiedToEntityRecord() {
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:10",
            name: "Barrel",
            kind: "mesh",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [0, 0, 0],
            components: ["transform", "mesh", "rigidbody", "collider", "audio_source"],
            rigidBodyMotionType: "dynamic",
            rigidBodyMass: 12.5,
            rigidBodyGravityScale: 0.8,
            rigidBodyAllowSleep: true,
            colliderShape: "capsule",
            colliderIsTrigger: false,
            colliderFriction: 0.6,
            colliderRestitution: 0.2,
            colliderDensity: 1.1,
            audioClip: "barrel_roll",
            audioVolume: 0.75,
            audioLoop: false,
            audioPlayOnAwake: true
        )
        var worldView = WorldView()
        worldView.apply(snapshot: SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity]))

        let r = worldView.entityIndex["scene:10"]
        XCTAssertEqual(r?.rigidBodyMotionType, "dynamic")
        XCTAssertEqual(r?.rigidBodyMass, 12.5)
        XCTAssertEqual(r?.rigidBodyGravityScale, 0.8)
        XCTAssertEqual(r?.rigidBodyAllowSleep, true)
        XCTAssertEqual(r?.colliderShape, "capsule")
        XCTAssertEqual(r?.colliderIsTrigger, false)
        XCTAssertEqual(r?.colliderFriction, 0.6)
        XCTAssertEqual(r?.colliderRestitution, 0.2)
        XCTAssertEqual(r?.colliderDensity, 1.1)
        XCTAssertEqual(r?.audioClip, "barrel_roll")
        XCTAssertEqual(r?.audioVolume, 0.75)
        XCTAssertEqual(r?.audioLoop, false)
        XCTAssertEqual(r?.audioPlayOnAwake, true)
    }

    func testWorldEntityRecordApplyPhysicsFromEvents() {
        var worldView = WorldView()
        worldView.apply(event: .entityAdded(ref: "scene:5", name: "Crate", kind: "mesh"))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:5", property: "rigidBodyMass", value: .float(8.0)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:5", property: "rigidBodyGravityScale", value: .float(0.5)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:5", property: "rigidBodyAllowSleep", value: .bool(false)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:5", property: "colliderShape", value: .string("box")))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:5", property: "colliderFriction", value: .float(0.4)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:5", property: "audioClip", value: .string("thud")))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:5", property: "audioLoop", value: .bool(true)))

        let r = worldView.entityIndex["scene:5"]
        XCTAssertEqual(r?.rigidBodyMass, 8.0)
        XCTAssertEqual(r?.rigidBodyGravityScale, 0.5)
        XCTAssertEqual(r?.rigidBodyAllowSleep, false)
        XCTAssertEqual(r?.colliderShape, "box")
        XCTAssertEqual(r?.colliderFriction, 0.4)
        XCTAssertEqual(r?.audioClip, "thud")
        XCTAssertEqual(r?.audioLoop, true)
    }

    func testSnapshotWorldEulerDegreesCopiedToEvaluatedDict() {
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:30",
            name: "TiltedChild",
            kind: "mesh",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [0, 0, 0],
            worldEulerDegrees: [30, 45, 0],
            components: ["transform", "mesh"]
        )
        var worldView = WorldView()
        worldView.apply(snapshot: SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity]))

        XCTAssertEqual(
            worldView.entityIndex["scene:30"]?.evaluated["worldEulerDegrees"],
            .vec3(30, 45, 0)
        )
    }

    func testSnapshotWithoutWorldEulerDegreesLeavesEvaluatedEmpty() {
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:31",
            name: "Upright",
            kind: "mesh",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [0, 0, 0],
            worldEulerDegrees: nil,
            components: ["transform", "mesh"]
        )
        var worldView = WorldView()
        worldView.apply(snapshot: SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity]))

        XCTAssertNil(worldView.entityIndex["scene:31"]?.evaluated["worldEulerDegrees"])
    }

    func testSnapshotWorldScaleCopiedToEvaluatedDict() {
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:32",
            name: "BigBox",
            kind: "mesh",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [0, 0, 0],
            worldScale: [2, 3, 4],
            components: ["transform", "mesh"]
        )
        var worldView = WorldView()
        worldView.apply(snapshot: SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity]))

        XCTAssertEqual(
            worldView.entityIndex["scene:32"]?.evaluated["worldScale"],
            .vec3(2, 3, 4)
        )
    }

    func testSnapshotWithoutWorldScaleLeavesEvaluatedEmpty() {
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:33",
            name: "Unit",
            kind: "mesh",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [0, 0, 0],
            worldScale: nil,
            components: ["transform", "mesh"]
        )
        var worldView = WorldView()
        worldView.apply(snapshot: SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity]))

        XCTAssertNil(worldView.entityIndex["scene:33"]?.evaluated["worldScale"])
    }

    func testSnapshotScriptBindingsCopiedToEntityRecord() {
        let binding = SceneSemanticSnapshot.ScriptBindingRecord(
            handle: 42,
            isEnabled: true,
            parametersJSON: "{\"speed\":5}"
        )
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:20",
            name: "Runner",
            kind: "mesh",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [0, 0, 0],
            components: ["transform", "script"],
            scriptBindings: [binding]
        )
        var worldView = WorldView()
        worldView.apply(snapshot: SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity]))

        let r = worldView.entityIndex["scene:20"]
        XCTAssertEqual(r?.scriptBindings?.count, 1)
        XCTAssertEqual(r?.scriptBindings?.first?.handle, 42)
        XCTAssertEqual(r?.scriptBindings?.first?.isEnabled, true)
        XCTAssertEqual(r?.scriptBindings?.first?.parametersJSON, "{\"speed\":5}")
    }

    func testJSONValueDecoding() throws {
        struct Wrapper: Decodable { var value: JSONValue }
        let stringData = #"{"value":"hello"}"#.data(using: .utf8)!
        let numberData = #"{"value":3.14}"#.data(using: .utf8)!
        let boolData   = #"{"value":true}"#.data(using: .utf8)!

        XCTAssertEqual(try JSONDecoder().decode(Wrapper.self, from: stringData).value, .string("hello"))
        XCTAssertEqual(try JSONDecoder().decode(Wrapper.self, from: numberData).value, .number(3.14))
        XCTAssertEqual(try JSONDecoder().decode(Wrapper.self, from: boolData).value, .bool(true))
    }

    func testJSONValueJsonFragment() {
        XCTAssertEqual(JSONValue.string("hi").jsonFragment, "\"hi\"")
        XCTAssertEqual(JSONValue.number(42).jsonFragment, "42")
        XCTAssertEqual(JSONValue.number(3.5).jsonFragment, "3.5")
        XCTAssertEqual(JSONValue.bool(false).jsonFragment, "false")
    }

    func testConfidenceEmptyPlanIsOne() {
        let plan = SceneEditPlan(summary: "Hello", steps: [])
        XCTAssertEqual(Session.confidence(for: plan), 1.0)
    }

    func testConfidenceSingleSafeOpIsOne() {
        let step = SceneEditStep(op: .setName, entityRef: "scene:1", name: "Hero")
        let plan = SceneEditPlan(summary: "rename", steps: [step])
        XCTAssertEqual(Session.confidence(for: plan), 1.0)
    }

    func testConfidenceMultipleStepsDecreases() {
        let steps = (0..<4).map { _ in SceneEditStep(op: .setName, entityRef: "scene:1", name: "X") }
        let plan = SceneEditPlan(summary: "multi", steps: steps)
        // 1.0 - 3 * 0.03 = 0.91
        XCTAssertEqual(Session.confidence(for: plan), 0.91, accuracy: 0.001)
    }

    func testConfidenceDestructiveOpAppliesPenalty() {
        let step = SceneEditStep(op: .deleteEntity, entityRef: "scene:1")
        let plan = SceneEditPlan(summary: "delete", steps: [step])
        // 1.0 - 0.10 (delete) - 0.05 (uncompensated delete, no spawn) = 0.85
        XCTAssertEqual(Session.confidence(for: plan), 0.85, accuracy: 0.001)
    }

    func testConfidenceDeleteWithSpawnIsNotUncompensated() {
        let steps = [
            SceneEditStep(op: .deleteEntity, entityRef: "scene:1"),
            SceneEditStep(op: .spawnEntity, name: "NewProp"),
        ]
        let plan = SceneEditPlan(summary: "replace", steps: steps)
        // 1.0 - 0.10 (delete) - 0.03 (extra step) - 0.05 (orphan spawn, no transform) = 0.82
        // No uncompensated delete penalty since hasSpawn = true
        XCTAssertEqual(Session.confidence(for: plan), 0.82, accuracy: 0.001)
    }

    func testConfidenceReasoningBonusApplied() {
        let step = SceneEditStep(op: .setName, entityRef: "scene:1", name: "Hero")
        var plan = SceneEditPlan(summary: "rename", steps: [step])
        plan.reasoning = "The user named this entity after the main character."
        // 1.0 + 0.05 (reasoning bonus) = 1.0 (capped at 1.0)
        XCTAssertEqual(Session.confidence(for: plan), 1.0, accuracy: 0.001)
    }

    func testConfidenceReasoningBonusAppliedWhenBelowOne() {
        let steps = (0..<4).map { _ in SceneEditStep(op: .setName, entityRef: "scene:1", name: "X") }
        var plan = SceneEditPlan(summary: "multi", steps: steps)
        plan.reasoning = "Renaming for clarity."
        // 1.0 - 3*0.03 + 0.05 = 0.91 - 0.09 + 0.05 = 0.96
        XCTAssertEqual(Session.confidence(for: plan), 0.96, accuracy: 0.001)
    }

    func testConfidenceFloorAt040() {
        let steps = (0..<30).map { _ in SceneEditStep(op: .deleteEntity, entityRef: "scene:1") }
        let plan = SceneEditPlan(summary: "massacre", steps: steps)
        XCTAssertGreaterThanOrEqual(Session.confidence(for: plan), 0.40)
    }

    func testConfidenceBroadImpactPenalty() {
        // 7 distinct entities → broadPenalty = 2 → -0.04
        let steps = (1...7).map { SceneEditStep(op: .setName, entityRef: "scene:\($0)", name: "X") }
        let plan = SceneEditPlan(summary: "rename many", steps: steps)
        let score = Session.confidence(for: plan)
        // 1.0 - 6*0.03 - 2*0.02 = 1.0 - 0.18 - 0.04 = 0.78
        XCTAssertEqual(score, 0.78, accuracy: 0.001)
    }

    func testConfidenceOrphanSpawnPenalty() {
        // Spawn with no follow-up transform → -0.05 extra
        let step = SceneEditStep(op: .spawnEntity, entityRef: nil, name: "Prop")
        let plan = SceneEditPlan(summary: "spawn", steps: [step])
        let score = Session.confidence(for: plan)
        // 1.0 - 0.05 = 0.95
        XCTAssertEqual(score, 0.95, accuracy: 0.001)
    }

    func testWorkflowContextGameSystemPromptSection() {
        let intent = GameplayIntent(genre: "third_person_shooter",
                                   winCondition: "eliminate_all",
                                   playerCount: 1,
                                   pacing: "tight_action")
        let ctx = GameWorkflowContext(levelPhase: .encounterDesign,
                                      gameplayIntent: intent,
                                      targetExperience: "Surrounded but escapable")
        let section = ctx.systemPromptSection
        XCTAssertTrue(section.contains("game/interactive"))
        XCTAssertTrue(section.contains("EncounterDesign"))
        XCTAssertTrue(section.contains("tight_action"))
        XCTAssertTrue(section.contains("Surrounded but escapable"))
    }

    func testWorkflowContextFilmSystemPromptSection() {
        let ctx = FilmWorkflowContext(
            activeSequenceID: "seq_010",
            activeShotID: "sh_020",
            narrativePhase: .lighting,
            directorIntent: "Moody noir feel",
            lockedShotIDs: ["sh_010"]
        )
        let section = ctx.systemPromptSection
        XCTAssertTrue(section.contains("cinematic / film"))
        XCTAssertTrue(section.contains("lighting"))
        XCTAssertTrue(section.contains("Moody noir feel"))
        XCTAssertTrue(section.contains("sh_010"))
    }

    func testWorkflowContextFilmReviewPhaseNotesSticktApproval() {
        let ctx = FilmWorkflowContext(activeSequenceID: "seq_010",
                                      narrativePhase: .review)
        let section = ctx.systemPromptSection
        XCTAssertTrue(section.contains("require explicit approval"))
    }

    func testWorkflowContextRoundTripsCodable() throws {
        let intent = GameplayIntent(genre: "puzzle_platformer", winCondition: "reach_exit")
        let game = GameWorkflowContext(levelPhase: .polish,
                                       gameplayIntent: intent,
                                       targetExperience: "Serene discovery")
        let context = WorkflowContext.game(game)
        let data = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(WorkflowContext.self, from: data)
        XCTAssertEqual(decoded, context)
    }

    func testSnapshotAnimationFieldsCopiedToEntityRecord() {
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:40",
            name: "Walker",
            kind: "mesh",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [0, 0, 0],
            components: ["transform", "mesh", "animation"],
            animationClip: "walk_cycle",
            animationSpeed: 1.5,
            animationLoop: true,
            animationIsPlaying: false
        )
        var worldView = WorldView()
        worldView.apply(snapshot: SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity]))

        let r = worldView.entityIndex["scene:40"]
        XCTAssertEqual(r?.animationClip, "walk_cycle")
        XCTAssertEqual(r?.animationSpeed, 1.5)
        XCTAssertEqual(r?.animationLoop, true)
        XCTAssertEqual(r?.animationIsPlaying, false)
    }

    func testSnapshotMeshIsVisibleFalseRecorded() {
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:41",
            name: "HiddenMesh",
            kind: "mesh",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [0, 0, 0],
            components: ["transform", "mesh"],
            meshIsVisible: false
        )
        var worldView = WorldView()
        worldView.apply(snapshot: SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity]))

        XCTAssertEqual(worldView.entityIndex["scene:41"]?.meshIsVisible, false)
    }

    func testSnapshotConstraintEnabledCopiedToEntityRecord() {
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:50",
            name: "Hinge",
            kind: "mesh",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [0, 0, 0],
            components: ["transform", "constraint"],
            constraintEnabled: false
        )
        var worldView = WorldView()
        worldView.apply(snapshot: SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity]))

        XCTAssertEqual(worldView.entityIndex["scene:50"]?.constraintEnabled, false)
    }

    func testEntityAuthoredChangedConstraintEnabledPopulatesRecord() {
        var worldView = WorldView()
        worldView.apply(event: .entityAdded(ref: "scene:51", name: "Joint", kind: "mesh"))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:51",
                                                      property: "constraintEnabled",
                                                      value: .bool(true)))
        XCTAssertEqual(worldView.entityIndex["scene:51"]?.constraintEnabled, true)
    }

    func testEntityAuthoredChangedAnimationFieldsPopulateRecord() {
        var worldView = WorldView()
        worldView.apply(event: .entityAdded(ref: "scene:42", name: "Dancer", kind: "mesh"))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:42", property: "animationClip", value: .string("dance")))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:42", property: "animationIsPlaying", value: .bool(true)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:42", property: "meshIsVisible", value: .bool(false)))

        let r = worldView.entityIndex["scene:42"]
        XCTAssertEqual(r?.animationClip, "dance")
        XCTAssertEqual(r?.animationIsPlaying, true)
        XCTAssertEqual(r?.meshIsVisible, false)
    }

    func testSessionCanBeSeededFromAIWorldContext() async {
        let context = AIWorldContext()
        await context.observe(events: [
            .entityAdded(ref: "scene:1", name: "Hero", kind: "mesh"),
            .entityInferredUpdated(ref: "scene:1",
                                   property: "object_category",
                                   value: .string("chair"),
                                   confidence: 0.91,
                                   source: "perception:fixture_classifier"),
        ])

        let session = Session(config: .openAI(apiKey: "test"))
        await session.replaceWorldView(await context.snapshot())

        let record = await session.entityRecord(ref: "scene:1")
        XCTAssertEqual(record?.inferred["object_category"]?.displayValue, "chair")
        XCTAssertEqual(record?.inferred["object_category"]?.source, "perception:fixture_classifier")
    }

    // MARK: - Camera FOV / active ops

    func testCameraFOVOpRoundTrips() throws {
        let json = """
        {"op":"set_camera_fov","entity_id":"scene:5","camera_fov_y":35.0}
        """
        let step = try JSONDecoder().decode(SceneEditStep.self, from: Data(json.utf8))
        XCTAssertEqual(step.op, .setCameraFOV)
        XCTAssertEqual(step.entityRef, "scene:5")
        XCTAssertEqual(step.cameraFovYDegrees, 35.0)
    }

    func testCameraActiveOpRoundTrips() throws {
        let json = """
        {"op":"set_camera_active","entity_id":"scene:7","camera_is_active":false}
        """
        let step = try JSONDecoder().decode(SceneEditStep.self, from: Data(json.utf8))
        XCTAssertEqual(step.op, .setCameraActive)
        XCTAssertEqual(step.cameraIsActive, false)
    }

    func testWorldEntityRecordApplyCameraFovFromEvent() {
        var view = WorldView()
        view.apply(event: .entityAdded(ref: "scene:9", name: "MainCamera", kind: "camera"))
        view.apply(event: .entityAuthoredChanged(ref: "scene:9",
                                                  property: "cameraFovYDegrees",
                                                  value: .float(50.0)))
        XCTAssertEqual(view.entityIndex["scene:9"]?.cameraFovYDegrees, 50.0)
    }

    func testWorldEntityRecordApplyCameraActiveFromEvent() {
        var view = WorldView()
        view.apply(event: .entityAdded(ref: "scene:10", name: "Cam", kind: "camera"))
        view.apply(event: .entityAuthoredChanged(ref: "scene:10",
                                                  property: "cameraIsActive",
                                                  value: .bool(false)))
        XCTAssertEqual(view.entityIndex["scene:10"]?.cameraIsActive, false)
    }

    func testLightCastShadowsOpRoundTrips() throws {
        let json = """
        {"op":"set_light_cast_shadows","entity_id":"scene:11","light_cast_shadows":true}
        """
        let step = try JSONDecoder().decode(SceneEditStep.self, from: Data(json.utf8))
        XCTAssertEqual(step.op, .setLightCastShadows)
        XCTAssertEqual(step.entityRef, "scene:11")
        XCTAssertEqual(step.lightCastShadows, true)
    }

    func testWorldEntityRecordApplyLightCastShadowsFromEvent() {
        var view = WorldView()
        view.apply(event: .entityAdded(ref: "scene:12", name: "Sun", kind: "light"))
        view.apply(event: .entityAuthoredChanged(ref: "scene:12",
                                                  property: "lightCastShadows",
                                                  value: .bool(true)))
        XCTAssertEqual(view.entityIndex["scene:12"]?.lightCastShadows, true)
    }

    func testSetScriptPropertyOpRoundTrips() throws {
        let json = """
        {"op":"set_script_property","entity_id":"scene:20","script_index":0,"script_property_name":"speed","script_property_value":5.0}
        """
        let step = try JSONDecoder().decode(SceneEditStep.self, from: Data(json.utf8))
        XCTAssertEqual(step.op, .setScriptProperty)
        XCTAssertEqual(step.entityRef, "scene:20")
        XCTAssertEqual(step.scriptIndex, 0)
        XCTAssertEqual(step.scriptPropertyName, "speed")
        XCTAssertEqual(step.scriptPropertyValue, .number(5.0))
    }

    func testSetScriptPropertyDefaultsScriptIndexToZero() throws {
        let json = """
        {"op":"set_script_property","entity_id":"scene:21","script_property_name":"label","script_property_value":"Patrol"}
        """
        let step = try JSONDecoder().decode(SceneEditStep.self, from: Data(json.utf8))
        XCTAssertNil(step.scriptIndex)
        XCTAssertEqual(step.scriptPropertyValue, .string("Patrol"))
    }

    func testJSONValueBoolRoundTrips() throws {
        let json = """
        {"op":"set_script_property","entity_id":"scene:22","script_property_name":"active","script_property_value":true}
        """
        let step = try JSONDecoder().decode(SceneEditStep.self, from: Data(json.utf8))
        XCTAssertEqual(step.scriptPropertyValue, .bool(true))
    }

    func testSetColliderLayerOpRoundTrips() throws {
        let json = """
        {"op":"set_collider_layer","entity_id":"scene:30","collider_layer_id":2,"collider_layer_mask":5}
        """
        let step = try JSONDecoder().decode(SceneEditStep.self, from: Data(json.utf8))
        XCTAssertEqual(step.op, .setColliderLayer)
        XCTAssertEqual(step.entityRef, "scene:30")
        XCTAssertEqual(step.colliderLayerID, 2)
        XCTAssertEqual(step.colliderLayerMask, 5)
    }

    func testSetColliderLayerExecutorEmitsBothMutations() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: .box(halfExtents: .one, center: .zero)), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"test","steps":[{"op":"set_collider_layer","entity_id":"\(ref)","collider_layer_id":3,"collider_layer_mask":12}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let executor = SceneEditPlanExecutor()
        let transaction = try executor.buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasLayer = ops.contains { if case .setColliderLayer(_, 3) = $0 { return true }; return false }
        let hasMask  = ops.contains { if case .setColliderLayerMask(_, 12) = $0 { return true }; return false }
        XCTAssertTrue(hasLayer, "expected setColliderLayer mutation")
        XCTAssertTrue(hasMask,  "expected setColliderLayerMask mutation")
    }

    func testSceneSemanticEncoderSurfacesColliderLayerAndMask() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(
            Collider(shape: .box(halfExtents: .one, center: .zero),
                     layerID: 4,
                     layerMask: 15),
            for: entity
        )

        let snapshot = SceneSemanticEncoder().encode(scene,
                                                     selectedEntityID: nil,
                                                     workspaceMode: "default",
                                                     localeIdentifier: nil)
        guard let entityRecord = snapshot.entities.first else {
            XCTFail("expected at least one entity in snapshot")
            return
        }
        XCTAssertEqual(entityRecord.colliderLayerID, 4)
        XCTAssertEqual(entityRecord.colliderLayerMask, 15)
    }

    func testWorldViewAppliesSnapshotWithColliderLayer() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(
            Collider(shape: .sphere(radius: 1, center: .zero), layerID: 7, layerMask: 63),
            for: entity
        )

        let snapshot = SceneSemanticEncoder().encode(scene, selectedEntityID: nil,
                                                     workspaceMode: "default",
                                                     localeIdentifier: nil)
        var worldView = WorldView()
        worldView.apply(snapshot: snapshot)

        let ref = "scene:\(entity.rawValue)"
        let record = worldView.entityIndex[ref]
        XCTAssertEqual(record?.colliderLayerID, 7)
        XCTAssertEqual(record?.colliderLayerMask, 63)
    }

    // MARK: - worldScale encoder

    func testSceneSemanticEncoderSurfacesWorldScaleForScaledEntity() {
        var scene = SceneRuntime()
        let parent = scene.createEntity()
        _ = scene.setComponent(LocalTransform(matrix: scaledMatrix(2, 3, 4)), for: parent)

        let child = scene.createEntity()
        scene.setParent(parent, for: child)
        _ = scene.setComponent(LocalTransform(translation: .zero), for: child)

        let snapshot = SceneSemanticEncoder().encode(scene, selectedEntityID: nil,
                                                     workspaceMode: "default",
                                                     localeIdentifier: nil)
        let parentRecord = snapshot.entities.first { $0.id == "scene:\(parent.rawValue)" }
        XCTAssertNotNil(parentRecord?.worldScale)
        if let ws = parentRecord?.worldScale {
            XCTAssertEqual(ws[0], 2, accuracy: 0.001)
            XCTAssertEqual(ws[1], 3, accuracy: 0.001)
            XCTAssertEqual(ws[2], 4, accuracy: 0.001)
        }
        // Child inherits parent scale; worldScale should also be [2,3,4].
        let childRecord = snapshot.entities.first { $0.id == "scene:\(child.rawValue)" }
        XCTAssertNotNil(childRecord?.worldScale)
        if let ws = childRecord?.worldScale {
            XCTAssertEqual(ws[0], 2, accuracy: 0.001)
            XCTAssertEqual(ws[1], 3, accuracy: 0.001)
            XCTAssertEqual(ws[2], 4, accuracy: 0.001)
        }
    }

    // MARK: - AIWorldContext SnapshotProvider

    func testAIWorldContextMaterializesSnapshot() async throws {
        let context = AIWorldContext()
        await context.observe(event: .entityAdded(ref: "scene:1", name: "Box", kind: "mesh"))

        let (snapshotID, cursor) = try await context.materializeSnapshot(scope: "scene")
        XCTAssertFalse(snapshotID.isEmpty)
        XCTAssertEqual(cursor.streamID, "world")
        XCTAssertGreaterThan(cursor.seq, 0)
    }

    func testAIWorldContextSnapshotCapturesStateAtCallTime() async throws {
        let context = AIWorldContext()
        await context.observe(event: .entityAdded(ref: "scene:1", name: "Pre", kind: "mesh"))

        let (snapshotID, _) = try await context.materializeSnapshot(scope: "scene")

        // Events after the snapshot should NOT appear in the captured WorldView.
        await context.observe(event: .entityAdded(ref: "scene:2", name: "Post", kind: "mesh"))

        let captured = await context.worldViewForSnapshot(snapshotID: snapshotID)
        XCTAssertNotNil(captured?.entityIndex["scene:1"])
        XCTAssertNil(captured?.entityIndex["scene:2"])
    }

    func testAIWorldContextSnapshotCursorAdvancesWithRevisions() async throws {
        let context = AIWorldContext()
        let (_, cursor1) = try await context.materializeSnapshot(scope: "scene")
        await context.observe(event: .entityAdded(ref: "scene:1", name: "A", kind: "mesh"))
        let (_, cursor2) = try await context.materializeSnapshot(scope: "scene")
        XCTAssertLessThan(cursor1.seq, cursor2.seq)
    }

    // MARK: - Helpers

    private func scaledMatrix(_ sx: Float, _ sy: Float, _ sz: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.0.x = sx
        m.columns.1.y = sy
        m.columns.2.z = sz
        return m
    }

    func testAIWorldContextEvictsOldestSnapshotAtLimit() async throws {
        let context = AIWorldContext()
        var ids: [String] = []
        for i in 0..<9 {
            await context.observe(event: .entityAdded(ref: "scene:\(i)", name: "E\(i)", kind: "mesh"))
            let (id, _) = try await context.materializeSnapshot(scope: "scene")
            ids.append(id)
        }
        // The first snapshot should have been evicted (limit is 8).
        let first = await context.worldViewForSnapshot(snapshotID: ids[0])
        XCTAssertNil(first)
        // The most recent ones should still be present.
        let last = await context.worldViewForSnapshot(snapshotID: ids[8])
        XCTAssertNotNil(last)
    }

    // MARK: - Session + ContextMemoryStore integration

    func testSessionForwardsEventsToContextMemory() async throws {
        let session = Session(id: "s1", config: makeTestConfig())
        let store = try ContextMemoryStore()
        await session.setContextMemory(store)
        await session.observe(event: .entityAdded(ref: "scene:1", name: "Rock", kind: "mesh"))
        // Give the fire-and-forget Task a tick to complete.
        try await Task.sleep(nanoseconds: 10_000_000)
        let entries = await store.allEntries()
        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(entries.first?.subject, "scene:1")
    }

    func testSessionForwardsBatchEventsToContextMemory() async throws {
        let session = Session(id: "s2", config: makeTestConfig())
        let store = try ContextMemoryStore()
        await session.setContextMemory(store)
        await session.observe(events: [
            .entityAdded(ref: "scene:2", name: "A", kind: nil),
            .entityAdded(ref: "scene:3", name: "B", kind: nil),
        ])
        try await Task.sleep(nanoseconds: 10_000_000)
        let count = await store.allEntries().count
        XCTAssertEqual(count, 2)
    }

    func testSessionContextMemoryNilByDefault() async throws {
        // Without setContextMemory, observe must not crash.
        let session = Session(id: "s3", config: makeTestConfig())
        await session.observe(event: .entityAdded(ref: "scene:4", name: "C", kind: nil))
        // No crash = pass.
    }

    // MARK: - issueTracked memory

    func testIssueMemoryRecordsEntryForEmptyPlan() async throws {
        let session = Session(id: "iss1", config: makeTestConfig())
        let store = try ContextMemoryStore()
        await session.setContextMemory(store)

        let emptyPlan = SceneEditPlan(summary: "Nothing to do.", steps: [])
        await session.updateIssueMemory(intent: "make it fly", plan: emptyPlan)
        try await Task.sleep(nanoseconds: 10_000_000)

        let entries = await store.lookup(kind: .issueTracked)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].payload["intent"], "make it fly")
        XCTAssertEqual(entries[0].payload["reason"], "Nothing to do.")
        XCTAssertEqual(entries[0].importance, 0.6, accuracy: 0.001)
    }

    func testIssueMemoryRemovesEntryWhenPlanIsNonEmpty() async throws {
        let session = Session(id: "iss2", config: makeTestConfig())
        let store = try ContextMemoryStore()
        await session.setContextMemory(store)

        let emptyPlan = SceneEditPlan(summary: "Cannot do that.", steps: [])
        await session.updateIssueMemory(intent: "rotate 45 degrees", plan: emptyPlan)
        try await Task.sleep(nanoseconds: 10_000_000)
        let beforeEntries = await store.lookup(kind: .issueTracked)
        XCTAssertFalse(beforeEntries.isEmpty)

        let step = SceneEditStep(op: .setTransform, entityRef: "scene:1")
        let resolvedPlan = SceneEditPlan(summary: "Done.", steps: [step])
        await session.updateIssueMemory(intent: "rotate 45 degrees", plan: resolvedPlan)
        try await Task.sleep(nanoseconds: 10_000_000)
        let afterEntries = await store.lookup(kind: .issueTracked)
        XCTAssertTrue(afterEntries.isEmpty)
    }

    func testIssueMemoryKeyIsStableAcrossIdenticalIntents() {
        let key1 = Session.issueKey(for: "add a point light")
        let key2 = Session.issueKey(for: "add a point light")
        XCTAssertEqual(key1, key2)
    }

    func testIssueMemoryKeyNormalizesSpecialChars() {
        let key = Session.issueKey(for: "what's going on?!")
        XCTAssertTrue(key.hasPrefix("issue:"))
        XCTAssertFalse(key.contains("'"))
        XCTAssertFalse(key.contains("?"))
        XCTAssertFalse(key.contains("!"))
    }

    func testIssueMemoryDoesNothingWithoutStore() async {
        let session = Session(id: "iss3", config: makeTestConfig())
        let emptyPlan = SceneEditPlan(summary: "empty", steps: [])
        await session.updateIssueMemory(intent: "test", plan: emptyPlan)
        // No crash = pass.
    }

    // MARK: - workflowContext memory

    func testSetWorkflowContextRecordsGameEntry() async throws {
        let session = Session(id: "wf1", config: makeTestConfig())
        let store = try ContextMemoryStore()
        await session.setContextMemory(store)

        let ctx = WorkflowContext.game(GameWorkflowContext(
            levelPhase: .polish,
            gameplayIntent: GameplayIntent(genre: "platformer", winCondition: "reach_exit"),
            targetExperience: "challenging but fair"
        ))
        await session.setWorkflowContext(ctx)
        try await Task.sleep(nanoseconds: 10_000_000)

        let entry = await store.entry(id: "workflow:active")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.kind, .workflowContext)
        XCTAssertEqual(entry?.payload["kind"], "game")
        XCTAssertEqual(entry?.payload["level_phase"], "Polish")
        XCTAssertEqual(entry?.payload["genre"], "platformer")
    }

    func testSetWorkflowContextRecordsFilmEntry() async throws {
        let session = Session(id: "wf2", config: makeTestConfig())
        let store = try ContextMemoryStore()
        await session.setContextMemory(store)

        let ctx = WorkflowContext.film(FilmWorkflowContext(
            activeSequenceID: "seq_01",
            activeShotID: "shot_05",
            narrativePhase: .cameraLanguage,
            directorIntent: "wide establishing shot"
        ))
        await session.setWorkflowContext(ctx)
        try await Task.sleep(nanoseconds: 10_000_000)

        let entry = await store.entry(id: "workflow:active")
        XCTAssertEqual(entry?.payload["kind"], "film")
        XCTAssertEqual(entry?.payload["narrative_phase"], "camera_language")
        XCTAssertEqual(entry?.payload["active_sequence"], "seq_01")
        XCTAssertEqual(entry?.payload["active_shot"], "shot_05")
        XCTAssertEqual(entry?.payload["director_intent"], "wide establishing shot")
    }

    func testSetWorkflowContextNilRemovesEntry() async throws {
        let session = Session(id: "wf3", config: makeTestConfig())
        let store = try ContextMemoryStore()
        await session.setContextMemory(store)

        let ctx = WorkflowContext.game(GameWorkflowContext(
            gameplayIntent: GameplayIntent(genre: "rpg", winCondition: "defeat_boss"),
            targetExperience: "epic"
        ))
        await session.setWorkflowContext(ctx)
        try await Task.sleep(nanoseconds: 10_000_000)
        let beforeEntry = await store.entry(id: "workflow:active")
        XCTAssertNotNil(beforeEntry)

        await session.setWorkflowContext(nil)
        try await Task.sleep(nanoseconds: 10_000_000)
        let afterEntry = await store.entry(id: "workflow:active")
        XCTAssertNil(afterEntry)
    }

    func testSetWorkflowContextWithoutStoreDoesNotCrash() async {
        let session = Session(id: "wf4", config: makeTestConfig())
        let ctx = WorkflowContext.film(FilmWorkflowContext(activeSequenceID: "x"))
        await session.setWorkflowContext(ctx)
    }

    // MARK: - sessionSummary memory

    func testClearHistoryRecordsSessionSummary() async throws {
        let session = Session(id: "sess1", config: makeTestConfig())
        let store = try ContextMemoryStore()
        await session.setContextMemory(store)

        await session.recordTurn(ConversationTurn(kind: .userText("place a spotlight above the stage")))
        await session.recordTurn(ConversationTurn(kind: .userText("set its color to warm white")))
        await session.clearHistory()
        try await Task.sleep(nanoseconds: 10_000_000)

        let entries = await store.lookup(kind: .sessionSummary)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, "summary:sess1")
        XCTAssertEqual(entries[0].payload["intent_count"], "2")
        XCTAssertTrue(entries[0].payload["last_intents"]?.contains("spotlight") ?? false)
    }

    func testClearHistoryWithNoUserTurnsRecordsNoSummary() async throws {
        let session = Session(id: "sess2", config: makeTestConfig())
        let store = try ContextMemoryStore()
        await session.setContextMemory(store)

        // Only a tool result turn — no user intents.
        await session.recordOutcome(toolUseID: "t1", content: "ok")
        await session.clearHistory()
        try await Task.sleep(nanoseconds: 10_000_000)
        let entries = await store.lookup(kind: .sessionSummary)
        XCTAssertTrue(entries.isEmpty)
    }

    func testClearHistoryDoesNotCrashWithoutStore() async {
        let session = Session(id: "sess3", config: makeTestConfig())
        await session.clearHistory()
    }

    func testClearHistorySummaryIsIdempotent() async throws {
        let session = Session(id: "sess4", config: makeTestConfig())
        let store = try ContextMemoryStore()
        await session.setContextMemory(store)

        // Two clear-history cycles with the same session ID must produce only one entry.
        await session.recordTurn(ConversationTurn(kind: .userText("first intent")))
        await session.clearHistory()

        await session.recordTurn(ConversationTurn(kind: .userText("second intent")))
        await session.clearHistory()
        try await Task.sleep(nanoseconds: 50_000_000)

        let entries = await store.lookup(kind: .sessionSummary)
        XCTAssertEqual(entries.count, 1, "same session ID produces exactly one summary entry")
    }

    func testIssueMemoryUpsertIsIdempotentForSameIntent() async throws {
        let session = Session(id: "iss4", config: makeTestConfig())
        let store = try ContextMemoryStore()
        await session.setContextMemory(store)

        let emptyPlan = SceneEditPlan(summary: "Can't do it.", steps: [])
        await session.updateIssueMemory(intent: "delete all", plan: emptyPlan)
        await session.updateIssueMemory(intent: "delete all", plan: emptyPlan)
        try await Task.sleep(nanoseconds: 10_000_000)

        let entries = await store.lookup(kind: .issueTracked)
        XCTAssertEqual(entries.count, 1)
    }

    // MARK: - set_material roundtrip

    func testSetMaterialOpRoundTripsAllFields() throws {
        let json = """
        {
            "op": "set_material",
            "entity_id": "scene:7",
            "material_base_color": [0.2, 0.4, 0.6, 1.0],
            "material_metallic": 0.8,
            "material_roughness": 0.3,
            "material_emissive": [0.1, 0.0, 0.5]
        }
        """
        let step = try JSONDecoder().decode(SceneEditStep.self, from: Data(json.utf8))
        XCTAssertEqual(step.op, .setMaterial)
        XCTAssertEqual(step.entityRef, "scene:7")
        XCTAssertEqual(step.materialBaseColor, [0.2, 0.4, 0.6, 1.0])
        XCTAssertEqual(step.materialMetallic ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(step.materialRoughness ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(step.materialEmissive, [0.1, 0.0, 0.5])
    }

    func testSetMaterialOpRoundTripsMinimalPayload() throws {
        let json = """
        {"op": "set_material", "entity_id": "scene:3", "material_base_color": [1.0, 0.0, 0.0, 1.0]}
        """
        let step = try JSONDecoder().decode(SceneEditStep.self, from: Data(json.utf8))
        XCTAssertEqual(step.op, .setMaterial)
        XCTAssertNil(step.materialMetallic)
        XCTAssertNil(step.materialRoughness)
        XCTAssertNil(step.materialEmissive)
    }

    func testWorldViewAppliesSnapshotWithMaterialFields() {
        var entity = SceneSemanticSnapshot.Entity(
            id: "scene:1",
            name: "Cube",
            kind: "mesh",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [0, 0, 0],
            components: ["transform", "mesh"]
        )
        entity.materialMetallic = 0.9
        entity.materialRoughness = 0.1
        entity.materialEmissive = [1.0, 0.5, 0.0]
        let snapshot = SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity])
        var view = WorldView()
        view.apply(snapshot: snapshot)
        let record = view.entityIndex["scene:1"]
        XCTAssertEqual(record?.materialMetallic ?? 0, 0.9, accuracy: 0.001)
        XCTAssertEqual(record?.materialRoughness ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(record?.materialEmissive, [1.0, 0.5, 0.0])
    }

    func testWorldViewAppliesSnapshotWithMaterialBaseColor() {
        var entity = SceneSemanticSnapshot.Entity(
            id: "scene:2",
            name: "RedCube",
            kind: "mesh",
            parentRef: nil,
            childRefs: [],
            isSelected: false,
            position: [0, 0, 0],
            components: ["transform", "mesh"]
        )
        entity.materialBaseColor = [1.0, 0.0, 0.0, 1.0]
        let snapshot = SceneSemanticSnapshot(sceneRevision: 1, entityCount: 1, entities: [entity])
        var view = WorldView()
        view.apply(snapshot: snapshot)
        XCTAssertEqual(view.entityIndex["scene:2"]?.materialBaseColor, [1.0, 0.0, 0.0, 1.0])
    }

    func testWorldEntityRecordApplyMaterialBaseColorFromEvent() {
        var record = WorldEntityRecord(ref: "scene:3", name: "Cube")
        record.apply(property: "materialBaseColor", value: .vec4(0.2, 0.4, 0.6, 1.0))
        XCTAssertEqual(record.materialBaseColor, [0.2, 0.4, 0.6, 1.0])
    }

    // MARK: - tagEntity perception integration

    func testTagEntityAppliesInferredEventsToWorldView() async throws {
        let session = Session(id: "percept1", config: makeTestConfig())

        let result = PerceptionResult(
            requestID: "r1",
            modelID: "fixture_classifier",
            modelVersion: "test",
            task: .classification,
            status: "success",
            observations: [
                .classification(ClassificationObservation(
                    id: "c0",
                    label: "chair",
                    labelSpace: "fixture",
                    confidence: 0.91,
                    semanticCandidates: [
                        PerceptionSemanticCandidate(kind: "object_category",
                                                    label: "chair",
                                                    confidence: 0.91),
                    ],
                    evidence: []
                )),
            ],
            timing: PerceptionTimingInfo(totalMilliseconds: 1),
            provenance: PerceptionProvenance(source: "fixture", modelID: "fixture_classifier")
        )

        let worker = StubPerceptionWorker(result: result)
        let service = PerceptionService()
        await service.register(worker)
        await session.setPerceptionService(service)

        // Seed a minimal entity in world view
        await session.observe(event: .entityAdded(ref: "scene:5", name: "Chair", kind: "mesh"))

        let events = try await session.tagEntity(ref: "scene:5",
                                                 imageURL: URL(fileURLWithPath: "/dev/null"),
                                                 task: .classification)
        XCTAssertFalse(events.isEmpty)

        // The inferred property should now be in the entity record
        let inferred = await session.worldView.entityIndex["scene:5"]?.inferred
        XCTAssertNotNil(inferred?["object_category"])
        XCTAssertEqual(inferred?["object_category"]?.displayValue, "chair")
    }

    func testTagEntityWithoutServiceThrows() async {
        let session = Session(id: "percept2", config: makeTestConfig())
        do {
            _ = try await session.tagEntity(ref: "scene:1",
                                            imageURL: URL(fileURLWithPath: "/dev/null"))
            XCTFail("Expected error when no service configured")
        } catch {
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("PerceptionService") || desc.contains("unavailable"),
                          "Unexpected error: \(desc)")
        }
    }

    func testTagEntityRecordsSceneAnnotationInMemory() async throws {
        let session = Session(id: "percept3", config: makeTestConfig())
        let store = try ContextMemoryStore()
        await session.setContextMemory(store)

        let result = PerceptionResult(
            requestID: "r2",
            modelID: "fixture_classifier",
            modelVersion: "test",
            task: .classification,
            status: "success",
            observations: [
                .classification(ClassificationObservation(
                    id: "c1",
                    label: "table",
                    labelSpace: "fixture",
                    confidence: 0.85,
                    semanticCandidates: [
                        PerceptionSemanticCandidate(kind: "object_category",
                                                    label: "table",
                                                    confidence: 0.85),
                    ],
                    evidence: []
                )),
            ],
            timing: PerceptionTimingInfo(totalMilliseconds: 1),
            provenance: PerceptionProvenance(source: "fixture", modelID: "fixture_classifier")
        )
        let worker = StubPerceptionWorker(result: result)
        let service = PerceptionService()
        await service.register(worker)
        await session.setPerceptionService(service)

        _ = try await session.tagEntity(ref: "scene:9",
                                        imageURL: URL(fileURLWithPath: "/dev/null"))
        try await Task.sleep(nanoseconds: 20_000_000)

        let annotations = await store.lookup(kind: .sceneAnnotation)
        XCTAssertFalse(annotations.isEmpty)
        XCTAssertTrue(annotations.allSatisfy { $0.subject == "scene:9" })
        let hasCategory = annotations.contains { $0.payload["property"] == "object_category" }
        XCTAssertTrue(hasCategory, "Expected object_category annotation")
    }

    private func makeTestConfig() -> SessionConfig {
        .anthropic(apiKey: "test")
    }
}

private final class StubPerceptionWorker: PerceptionWorker, @unchecked Sendable {
    let result: PerceptionResult
    init(result: PerceptionResult) { self.result = result }

    var manifest: PerceptionModelManifest {
        PerceptionModelManifest(
            modelID: "fixture_classifier",
            displayName: "Fixture",
            task: .classification,
            backendFamily: "test",
            runtime: PerceptionRuntimeConfig(preferredRuntime: "none"),
            inputContract: "",
            outputContract: "",
            license: PerceptionLicenseMetadata(codeLicense: "MIT", weightsLicense: "MIT",
                                               commercialUse: "allowed",
                                               redistribution: "allowed")
        )
    }

    func analyzeImage(at url: URL, requestID: String, maxResults: Int) throws -> PerceptionResult {
        result
    }
}
