@testable import AIRuntime
import IntentRuntime
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
        // 1.0 - 0.10 = 0.90
        XCTAssertEqual(Session.confidence(for: plan), 0.90, accuracy: 0.001)
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
}
