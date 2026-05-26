@testable import AIRuntime
import ContextMemory
import IntentRuntime
import PerceptionRuntime
import SceneRuntime
import ScriptRuntime
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

    func testWorldEntityRecordApplyLightPropertiesFromEvents() {
        var worldView = WorldView()
        worldView.apply(event: .entityAdded(ref: "scene:L", name: "Sun", kind: "light"))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:L", property: "lightType", value: .string("directional")))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:L", property: "lightIntensity", value: .float(1200)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:L", property: "lightColor", value: .vec3(1, 0.95, 0.8)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:L", property: "lightRange", value: .float(50)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:L", property: "lightSpotInner", value: .float(15)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:L", property: "lightSpotOuter", value: .float(30)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:L", property: "lightCastShadows", value: .bool(true)))

        let r = worldView.entityIndex["scene:L"]
        XCTAssertEqual(r?.lightType, "directional")
        XCTAssertEqual(r?.lightIntensity, 1200)
        XCTAssertEqual(r?.lightColor, [1, 0.95, 0.8])
        XCTAssertEqual(r?.lightRange, 50)
        XCTAssertEqual(r?.lightSpotInner, 15)
        XCTAssertEqual(r?.lightSpotOuter, 30)
        XCTAssertEqual(r?.lightCastShadows, true)
    }

    func testWorldEntityRecordApplyColliderGranularFieldsFromEvents() {
        var worldView = WorldView()
        worldView.apply(event: .entityAdded(ref: "scene:C", name: "Box", kind: "mesh"))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:C", property: "colliderIsTrigger", value: .bool(true)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:C", property: "colliderRestitution", value: .float(0.7)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:C", property: "colliderDensity", value: .float(2.5)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:C", property: "colliderLayerID", value: .float(4)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:C", property: "colliderLayerMask", value: .float(255)))

        let r = worldView.entityIndex["scene:C"]
        XCTAssertEqual(r?.colliderIsTrigger, true)
        XCTAssertEqual(r?.colliderRestitution, 0.7)
        XCTAssertEqual(r?.colliderDensity, 2.5)
        XCTAssertEqual(r?.colliderLayerID, 4)
        XCTAssertEqual(r?.colliderLayerMask, 255)
    }

    func testWorldEntityRecordApplyMeshAndAudioFromEvents() {
        var worldView = WorldView()
        worldView.apply(event: .entityAdded(ref: "scene:M", name: "Prop", kind: "mesh"))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:M", property: "meshIsVisible", value: .bool(false)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:M", property: "meshColor", value: .vec3(0.2, 0.5, 1.0)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:M", property: "audioVolume", value: .float(0.8)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:M", property: "audioPlayOnAwake", value: .bool(false)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:M", property: "rigidBodyMotionType", value: .string("kinematic")))

        let r = worldView.entityIndex["scene:M"]
        XCTAssertEqual(r?.meshIsVisible, false)
        XCTAssertEqual(r?.meshColor, [0.2, 0.5, 1.0])
        XCTAssertEqual(r?.audioVolume, 0.8)
        XCTAssertEqual(r?.audioPlayOnAwake, false)
        XCTAssertEqual(r?.rigidBodyMotionType, "kinematic")
    }

    func testWorldEntityRecordApplyRemainingMaterialFieldsFromEvents() {
        var worldView = WorldView()
        worldView.apply(event: .entityAdded(ref: "scene:X", name: "Metal", kind: "mesh"))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:X", property: "materialMetallic", value: .float(0.9)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:X", property: "materialRoughness", value: .float(0.1)))
        worldView.apply(event: .entityAuthoredChanged(ref: "scene:X", property: "materialEmissive", value: .vec3(0, 0.5, 1)))

        let r = worldView.entityIndex["scene:X"]
        XCTAssertEqual(r?.materialMetallic, 0.9)
        XCTAssertEqual(r?.materialRoughness, 0.1)
        XCTAssertEqual(r?.materialEmissive, [0, 0.5, 1])
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

    func testSetColliderShapeExecutorProducesShapeTypeMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: .box(halfExtents: .one, center: .zero)), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"spherify","steps":[{"op":"set_collider_shape","entity_id":"\(ref)","collider_shape":"sphere"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasShape = ops.contains {
            if case .setColliderShapeType(_, .sphere) = $0 { return true }
            return false
        }
        XCTAssertTrue(hasShape, "set_collider_shape sphere must produce setColliderShapeType(.sphere) mutation")
    }

    func testSetColliderMaterialExecutorProducesThreeMutations() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: .box(halfExtents: .one, center: .zero)), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"icy","steps":[{"op":"set_collider_material","entity_id":"\(ref)",\
        "friction":0.05,"restitution":0.9,"density":0.8}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasFriction    = ops.contains { if case .setColliderMaterialFriction(_, _) = $0 { return true }; return false }
        let hasRestitution = ops.contains { if case .setColliderMaterialRestitution(_, _) = $0 { return true }; return false }
        let hasDensity     = ops.contains { if case .setColliderMaterialDensity(_, _) = $0 { return true }; return false }
        XCTAssertTrue(hasFriction,    "set_collider_material must produce setColliderMaterialFriction mutation")
        XCTAssertTrue(hasRestitution, "set_collider_material must produce setColliderMaterialRestitution mutation")
        XCTAssertTrue(hasDensity,     "set_collider_material must produce setColliderMaterialDensity mutation")
    }

    func testSetScriptPropertyExecutorMergesIntoExistingBindings() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let existingBinding = ScriptBinding(ScriptHandle(rawValue: 7),
                                            isEnabled: true,
                                            parametersJSON: #"{"speed":1.0}"#)
        _ = scene.setComponent(ScriptComponent(bindings: [existingBinding]), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"set speed","steps":[{"op":"set_script_property","entity_id":"\(ref)",\
        "script_index":0,"script_property_name":"speed","script_property_value":5.0}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        var foundBindings: [ScriptBinding]? = nil
        for op in ops {
            if case let .setScriptBindings(_, bindings) = op { foundBindings = bindings; break }
        }
        let bindings = try XCTUnwrap(foundBindings, "expected setScriptBindings mutation")
        XCTAssertEqual(bindings.count, 1)
        let params = try XCTUnwrap(bindings[0].parametersJSON.data(using: .utf8))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: Any])
        XCTAssertEqual(dict["speed"] as? Double, 5.0, "merged speed should be 5.0")
        XCTAssertEqual(bindings[0].script.rawValue, 7, "script handle must be preserved")
    }

    func testSetScriptPropertyExecutorCreatesBindingWhenComponentAbsent() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"add label","steps":[{"op":"set_script_property","entity_id":"\(ref)",\
        "script_property_name":"label","script_property_value":"Patrol"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        var foundBindings: [ScriptBinding]? = nil
        for op in ops {
            if case let .setScriptBindings(_, bindings) = op { foundBindings = bindings; break }
        }
        let bindings = try XCTUnwrap(foundBindings, "expected setScriptBindings mutation")
        XCTAssertEqual(bindings.count, 1, "executor must create a binding when none exist")
        let params = try XCTUnwrap(bindings[0].parametersJSON.data(using: .utf8))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: params) as? [String: Any])
        XCTAssertEqual(dict["label"] as? String, "Patrol")
    }

    func testSetColliderTriggerExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: .box(halfExtents: .one, center: .zero)), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"trigger","steps":[{"op":"set_collider_trigger","entity_id":"\(ref)","is_trigger":true}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasTrigger = ops.contains { if case .setColliderTrigger(_, true) = $0 { return true }; return false }
        XCTAssertTrue(hasTrigger, "set_collider_trigger must produce setColliderTrigger mutation")
    }

    func testSetColliderBoxExtentsExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: .box(halfExtents: .one, center: .zero)), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"extents","steps":[{"op":"set_collider_box_extents","entity_id":"\(ref)",\
        "half_extents":[0.5,1.0,2.0]}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasExtents = ops.contains {
            if case let .setColliderShapeBoxHalfExtents(_, ext) = $0 {
                return abs(ext.x - 0.5) < 0.001 && abs(ext.y - 1.0) < 0.001 && abs(ext.z - 2.0) < 0.001
            }
            return false
        }
        XCTAssertTrue(hasExtents, "set_collider_box_extents must produce setColliderShapeBoxHalfExtents mutation")
    }

    func testSetColliderSphereRadiusExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: .sphere(radius: 1, center: .zero)), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"sphere","steps":[{"op":"set_collider_sphere_radius","entity_id":"\(ref)","radius":3.5}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasRadius = ops.contains {
            if case let .setColliderShapeSphereRadius(_, r) = $0 { return abs(r - 3.5) < 0.001 }
            return false
        }
        XCTAssertTrue(hasRadius, "set_collider_sphere_radius must produce setColliderShapeSphereRadius mutation")
    }

    func testSetColliderCapsuleExecutorProducesBothMutations() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: .box(halfExtents: .one, center: .zero)), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"capsule","steps":[{"op":"set_collider_capsule","entity_id":"\(ref)",\
        "radius":0.4,"half_height":1.2}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasRadius = ops.contains {
            if case let .setColliderShapeCapsuleRadius(_, r) = $0 { return abs(r - 0.4) < 0.001 }
            return false
        }
        let hasHH = ops.contains {
            if case let .setColliderShapeCapsuleHalfHeight(_, hh) = $0 { return abs(hh - 1.2) < 0.001 }
            return false
        }
        XCTAssertTrue(hasRadius, "set_collider_capsule must produce setColliderShapeCapsuleRadius mutation")
        XCTAssertTrue(hasHH,     "set_collider_capsule must produce setColliderShapeCapsuleHalfHeight mutation")
    }

    func testSetConstraintEnabledExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"constraint","steps":[{"op":"set_constraint_enabled","entity_id":"\(ref)","is_enabled":false}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasConstraint = ops.contains { if case .setConstraintEnabled(_, false) = $0 { return true }; return false }
        XCTAssertTrue(hasConstraint, "set_constraint_enabled must produce setConstraintEnabled mutation")
    }

    func testSetRigidBodyAllowSleepExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"sleep","steps":[{"op":"set_rigidbody_allow_sleep","entity_id":"\(ref)","allow_sleep":true}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasSleep = ops.contains { if case .setRigidBodyAllowSleep(_, true) = $0 { return true }; return false }
        XCTAssertTrue(hasSleep, "set_rigid_body_allow_sleep must produce setRigidBodyAllowSleep mutation")
    }

    func testSetMeshVisibilityExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"hide","steps":[{"op":"set_mesh_visibility","entity_id":"\(ref)","is_visible":false}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasVisibility = ops.contains { if case .setRenderMeshVisibility(_, false) = $0 { return true }; return false }
        XCTAssertTrue(hasVisibility, "set_mesh_visibility must produce setRenderMeshVisibility mutation")
    }

    func testSetLightTypeExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(LightComponent(type: .point, color: .one, intensity: 100, range: 10), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"spot","steps":[{"op":"set_light_type","entity_id":"\(ref)","light_type":"spot"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasType = ops.contains { if case .setLightType(_, .spot) = $0 { return true }; return false }
        XCTAssertTrue(hasType, "set_light_type must produce setLightType(.spot) mutation")
    }

    func testSetLightIntensityExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(LightComponent(type: .directional, color: .one, intensity: 1, range: 100), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"brighter","steps":[{"op":"set_light_intensity","entity_id":"\(ref)","intensity":800}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasIntensity = ops.contains {
            if case let .setLightIntensity(_, v) = $0 { return abs(v - 800) < 0.01 }
            return false
        }
        XCTAssertTrue(hasIntensity, "set_light_intensity must produce setLightIntensity mutation")
    }

    func testSetLightColorExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(LightComponent(type: .point, color: .one, intensity: 100, range: 10), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"warm","steps":[{"op":"set_light_color","entity_id":"\(ref)","color":[1.0,0.8,0.4]}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasColor = ops.contains {
            if case let .setLightColor(_, c) = $0 { return abs(c.x - 1.0) < 0.01 && abs(c.y - 0.8) < 0.01 }
            return false
        }
        XCTAssertTrue(hasColor, "set_light_color must produce setLightColor mutation")
    }

    func testSetLightRangeExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(LightComponent(type: .point, color: .one, intensity: 100, range: 10), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"range","steps":[{"op":"set_light_range","entity_id":"\(ref)","range":35.0}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasRange = ops.contains {
            if case let .setLightRange(_, r) = $0 { return abs(r - 35) < 0.01 }
            return false
        }
        XCTAssertTrue(hasRange, "set_light_range must produce setLightRange mutation")
    }

    func testSetLightSpotAnglesExecutorProducesBothMutations() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(LightComponent(type: .spot, color: .one, intensity: 100, range: 20), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"cone","steps":[{"op":"set_light_spot_angles","entity_id":"\(ref)",\
        "spot_inner_angle":15.0,"spot_outer_angle":40.0}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasInner = ops.contains {
            if case let .setLightSpotInnerAngle(_, a) = $0 { return abs(a - 15) < 0.01 }
            return false
        }
        let hasOuter = ops.contains {
            if case let .setLightSpotOuterAngle(_, a) = $0 { return abs(a - 40) < 0.01 }
            return false
        }
        XCTAssertTrue(hasInner, "set_light_spot_angles must produce setLightSpotInnerAngle mutation")
        XCTAssertTrue(hasOuter, "set_light_spot_angles must produce setLightSpotOuterAngle mutation")
    }

    func testSetMeshColorExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RenderMeshComponent(meshIndex: 0), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"tint","steps":[{"op":"set_mesh_color","entity_id":"\(ref)","color":[0.2,0.5,0.9]}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasTint = ops.contains {
            if case let .setMeshColorTint(_, c) = $0 {
                return abs(c.x - 0.2) < 0.01 && abs(c.y - 0.5) < 0.01 && abs(c.z - 0.9) < 0.01
            }
            return false
        }
        XCTAssertTrue(hasTint, "set_mesh_color must produce setMeshColorTint mutation")
    }

    func testSetCameraFOVExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(CameraComponent(), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"fov","steps":[{"op":"set_camera_fov","entity_id":"\(ref)","camera_fov_y":90.0}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasFOV = ops.contains {
            if case let .setCameraFOV(_, fov) = $0 { return abs(fov - 90) < 0.01 }
            return false
        }
        XCTAssertTrue(hasFOV, "set_camera_fov must produce setCameraFOV mutation")
    }

    func testSetCameraActiveExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(CameraComponent(), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"activate","steps":[{"op":"set_camera_active","entity_id":"\(ref)","camera_is_active":true}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasActive = ops.contains { if case .setCameraActive(_, true) = $0 { return true }; return false }
        XCTAssertTrue(hasActive, "set_camera_active must produce setCameraActive mutation")
    }

    func testSetRigidBodyMotionExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RigidBody(motionType: .dynamic, mass: 1, gravityScale: 1, allowSleep: true),
                                for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"kinematic","steps":[{"op":"set_rigidbody_motion","entity_id":"\(ref)","motion_type":"kinematic"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasMotion = ops.contains { if case .setRigidBodyMotionType(_, .kinematic) = $0 { return true }; return false }
        XCTAssertTrue(hasMotion, "set_rigidbody_motion must produce setRigidBodyMotionType(.kinematic) mutation")
    }

    func testSetRigidBodyMassExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RigidBody(motionType: .dynamic, mass: 1, gravityScale: 1, allowSleep: true),
                                for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"mass","steps":[{"op":"set_rigidbody_mass","entity_id":"\(ref)","mass":25.0}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasMass = ops.contains {
            if case let .setRigidBodyMass(_, v) = $0 { return abs(v - 25) < 0.01 }
            return false
        }
        XCTAssertTrue(hasMass, "set_rigidbody_mass must produce setRigidBodyMass mutation")
    }

    func testSetRigidBodyGravityExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RigidBody(motionType: .dynamic, mass: 1, gravityScale: 1, allowSleep: true),
                                for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"gravity","steps":[{"op":"set_rigidbody_gravity","entity_id":"\(ref)","gravity_scale":0.2}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasGravity = ops.contains {
            if case let .setRigidBodyGravityScale(_, v) = $0 { return abs(v - 0.2) < 0.001 }
            return false
        }
        XCTAssertTrue(hasGravity, "set_rigidbody_gravity must produce setRigidBodyGravityScale mutation")
    }

    func testSetTransformPositionOnlyPreservesExistingTransform() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        // Give entity a non-identity transform with y=5
        var initial = LocalTransform()
        initial.matrix.columns.3 = SIMD4<Float>(0, 5, 0, 1)
        _ = scene.setLocalTransform(initial, for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"move","steps":[{"op":"set_transform","entity_id":"\(ref)","position":[10,20,30]}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        var foundTransform: LocalTransform? = nil
        for op in ops {
            if case let .setLocalTransform(_, t) = op { foundTransform = t; break }
        }
        let t = try XCTUnwrap(foundTransform)
        XCTAssertEqual(t.translation.x, 10, accuracy: 0.01)
        XCTAssertEqual(t.translation.y, 20, accuracy: 0.01)
        XCTAssertEqual(t.translation.z, 30, accuracy: 0.01)
    }

    func testSnapToGroundExecutorZerosYTranslation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        var elevated = LocalTransform()
        elevated.matrix.columns.3 = SIMD4<Float>(3, 8, 1, 1)
        _ = scene.setLocalTransform(elevated, for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"ground","steps":[{"op":"snap_to_ground","entity_id":"\(ref)"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        var foundTransform: LocalTransform? = nil
        for op in ops { if case let .setLocalTransform(_, t) = op { foundTransform = t; break } }
        let t = try XCTUnwrap(foundTransform)
        XCTAssertEqual(t.translation.y, 0, accuracy: 0.001, "snap_to_ground must zero Y translation")
        XCTAssertEqual(t.translation.x, 3, accuracy: 0.01,  "snap_to_ground must preserve X translation")
        XCTAssertEqual(t.translation.z, 1, accuracy: 0.01,  "snap_to_ground must preserve Z translation")
    }

    func testSetNameExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"rename","steps":[{"op":"set_name","entity_id":"\(ref)","name":"HeroChar"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasName = ops.contains { if case .setSceneName(_, "HeroChar") = $0 { return true }; return false }
        XCTAssertTrue(hasName, "set_name must produce setSceneName mutation")
    }

    func testDeleteEntityExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"delete","steps":[{"op":"delete_entity","entity_id":"\(ref)"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasDelete = ops.contains { if case .deleteEntity(entity.rawValue) = $0 { return true }; return false }
        XCTAssertTrue(hasDelete, "delete_entity must produce deleteEntity mutation")
    }

    func testSpawnEntityExecutorProducesMutation() throws {
        var scene = SceneRuntime()

        let json = """
        {"summary":"spawn","steps":[{"op":"spawn_entity","label":"Barrel","spawn_position":[0,0,5]}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasSpawn = ops.contains {
            if case let .spawnImportedMeshEntity(label, _, _, pos) = $0 {
                return label == "Barrel" && abs(pos.z - 5) < 0.01
            }
            return false
        }
        XCTAssertTrue(hasSpawn, "spawn_entity must produce spawnImportedMeshEntity mutation with correct label and position")
    }

    func testDuplicateEntityExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"dup","steps":[{"op":"duplicate_entity","entity_id":"\(ref)"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasDup = ops.contains { if case .duplicateEntity(entity.rawValue) = $0 { return true }; return false }
        XCTAssertTrue(hasDup, "duplicate_entity must produce duplicateEntity mutation")
    }

    func testReparentEntityToRootExecutorProducesMoveEntityMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"reparent","steps":[{"op":"reparent_entity","entity_id":"\(ref)"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasMove = ops.contains {
            if case let .moveEntity(eid, parentID, _) = $0 {
                return eid == entity.rawValue && parentID == nil
            }
            return false
        }
        XCTAssertTrue(hasMove, "reparent_entity with no parent_id must produce moveEntity(parentID: nil)")
    }

    func testSetLightCastShadowsExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(LightComponent(type: .directional, color: .one, intensity: 1, range: 100), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"shadow","steps":[{"op":"set_light_cast_shadows","entity_id":"\(ref)","light_cast_shadows":true}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasCast = ops.contains { if case .setLightCastShadows(_, true) = $0 { return true }; return false }
        XCTAssertTrue(hasCast, "set_light_cast_shadows must produce setLightCastShadows mutation")
    }

    func testSetCameraPoseExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(CameraComponent(), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"pose","steps":[{"op":"set_camera_pose","entity_id":"\(ref)",\
        "position":[5,3,10],"camera_target":[0,0,0]}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasPose = ops.contains {
            if case let .setCameraPose(_, t, target, _) = $0 {
                return abs(t.translation.x - 5) < 0.01
                    && abs(t.translation.z - 10) < 0.01
                    && abs(target.x) < 0.01
            }
            return false
        }
        XCTAssertTrue(hasPose, "set_camera_pose must produce setCameraPose mutation with correct position and target")
    }

    func testExecutorThrowsUnknownColliderShape() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: .box(halfExtents: .one, center: .zero)), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"bad","steps":[{"op":"set_collider_shape","entity_id":"\(ref)","collider_shape":"cylinder"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        XCTAssertThrowsError(try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)) { err in
            if case SceneEditPlanExecutorError.unknownColliderShape(let s) = err {
                XCTAssertEqual(s, "cylinder")
            } else {
                XCTFail("expected unknownColliderShape, got \(err)")
            }
        }
    }

    func testExecutorThrowsUnknownLightType() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(LightComponent(type: .point, color: .one, intensity: 100, range: 10), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"bad","steps":[{"op":"set_light_type","entity_id":"\(ref)","light_type":"laser"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        XCTAssertThrowsError(try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)) { err in
            if case SceneEditPlanExecutorError.unknownLightType(let s) = err {
                XCTAssertEqual(s, "laser")
            } else {
                XCTFail("expected unknownLightType, got \(err)")
            }
        }
    }

    func testExecutorThrowsUnknownMotionType() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RigidBody(motionType: .dynamic, mass: 1, gravityScale: 1, allowSleep: true),
                                for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"bad","steps":[{"op":"set_rigidbody_motion","entity_id":"\(ref)","motion_type":"fluid"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        XCTAssertThrowsError(try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)) { err in
            if case SceneEditPlanExecutorError.unknownMotionType(let s) = err {
                XCTAssertEqual(s, "fluid")
            } else {
                XCTFail("expected unknownMotionType, got \(err)")
            }
        }
    }

    func testExecutorThrowsMissingFieldForSetName() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"empty name","steps":[{"op":"set_name","entity_id":"\(ref)","name":""}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        XCTAssertThrowsError(try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)) { err in
            if case SceneEditPlanExecutorError.missingField(_, let field) = err {
                XCTAssertEqual(field, "name")
            } else {
                XCTFail("expected missingField(name), got \(err)")
            }
        }
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

    func testSetAnimationPlayerExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(AnimationPlayer(), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"play walk","steps":[{"op":"set_animation_player","entity_id":"\(ref)",\
        "animation_clip":"walk","animation_speed":1.5,"animation_loop":true,"animation_is_playing":true}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasAnim = ops.contains {
            if case let .setAnimationPlayer(id, clip, speed, loop, playing) = $0 {
                return id == entity.rawValue
                    && clip == "walk"
                    && abs(speed - 1.5) < 0.001
                    && loop == true
                    && playing == true
            }
            return false
        }
        XCTAssertTrue(hasAnim, "set_animation_player must produce a setAnimationPlayer mutation")
    }

    func testSceneSemanticEncoderSurfacesSpotLightAngles() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        var light = LightComponent()
        light.type = .spot
        light.intensity = 2000
        light.spotInnerAngleDegrees = 15.0
        light.spotOuterAngleDegrees = 30.0
        _ = scene.setComponent(light, for: entity)

        let snapshot = SceneSemanticEncoder().encode(scene, selectedEntityID: nil,
                                                     workspaceMode: nil, localeIdentifier: nil)
        let record = snapshot.entities.first { $0.id == "scene:\(entity.rawValue)" }
        XCTAssertEqual(record?.lightType, "spot")
        XCTAssertEqual(record?.lightSpotInner ?? 0, 15.0, accuracy: 0.1)
        XCTAssertEqual(record?.lightSpotOuter ?? 0, 30.0, accuracy: 0.1)
        XCTAssertNil(record?.lightCastShadows)
    }

    func testWorldEntityRecordApplyScriptBindingsFromJSONEvent() {
        var record = WorldEntityRecord(ref: "scene:99", name: "Mover")
        let json = #"[{"handle":42,"isEnabled":true,"parametersJSON":"{\"speed\":5}"}]"#
        record.apply(property: "scriptBindings", value: .string(json))
        XCTAssertEqual(record.scriptBindings?.count, 1)
        XCTAssertEqual(record.scriptBindings?.first?.handle, 42)
        XCTAssertEqual(record.scriptBindings?.first?.isEnabled, true)
        XCTAssertEqual(record.scriptBindings?.first?.parametersJSON, #"{"speed":5}"#)
    }

    func testSceneSemanticEncoderSurfacesConstraintEnabled() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        var con = Constraint(entityA: entity, entityB: entity)
        con.isEnabled = false
        _ = scene.setComponent(con, for: entity)

        let snapshot = SceneSemanticEncoder().encode(scene, selectedEntityID: nil,
                                                     workspaceMode: nil, localeIdentifier: nil)
        let record = snapshot.entities.first { $0.id == "scene:\(entity.rawValue)" }
        XCTAssertEqual(record?.constraintEnabled, false)
    }

    func testSetAudioSourceExecutorProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(AudioSource(), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"add music","steps":[{"op":"set_audio_source","entity_id":"\(ref)",\
        "audio_clip":"theme","audio_volume":0.8,"audio_loop":true,"audio_play_on_awake":true}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasAudio = ops.contains {
            if case let .setAudioSource(id, src) = $0 {
                return id == entity.rawValue
                    && src.clipName == "theme"
                    && abs(src.volume - 0.8) < 0.001
                    && src.loop == true
                    && src.playOnAwake == true
            }
            return false
        }
        XCTAssertTrue(hasAudio, "set_audio_source must produce a setAudioSource mutation")
    }

    func testSceneSemanticEncoderSurfacesRigidBodyAndColliderFields() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(
            RigidBody(motionType: .kinematic, mass: 7.5, gravityScale: 0.5, allowSleep: false),
            for: entity
        )
        _ = scene.setComponent(
            Collider(shape: .sphere(radius: 2.0, center: .zero),
                     isTrigger: true,
                     layerID: 2,
                     layerMask: 7,
                     material: PhysicsMaterial(friction: 0.2, restitution: 0.8, density: 1.5)),
            for: entity
        )

        let snapshot = SceneSemanticEncoder().encode(scene, selectedEntityID: nil,
                                                     workspaceMode: nil, localeIdentifier: nil)
        guard let record = snapshot.entities.first(where: { $0.id == "scene:\(entity.rawValue)" }) else {
            XCTFail("entity not found in snapshot"); return
        }
        XCTAssertEqual(record.rigidBodyMotionType, "kinematic")
        XCTAssertEqual(record.rigidBodyMass ?? 0,         7.5, accuracy: 0.001)
        XCTAssertEqual(record.rigidBodyGravityScale ?? 1, 0.5, accuracy: 0.001)
        XCTAssertEqual(record.rigidBodyAllowSleep, false)
        XCTAssertEqual(record.colliderShape, "sphere")
        XCTAssertEqual(record.colliderIsTrigger, true)
        XCTAssertEqual(record.colliderFriction ?? 0,     0.2, accuracy: 0.001)
        XCTAssertEqual(record.colliderRestitution ?? 0,  0.8, accuracy: 0.001)
        XCTAssertEqual(record.colliderDensity ?? 0,      1.5, accuracy: 0.001)
    }

    func testSceneSemanticEncoderSurfacesAudioAndAnimationFields() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        var audio = AudioSource()
        audio.clipName = "ambient_loop"
        audio.volume = 0.6
        audio.loop = true
        audio.playOnAwake = false
        _ = scene.setComponent(audio, for: entity)
        var anim = AnimationPlayer()
        anim.clipName = "idle"
        anim.speed = 1.5
        anim.loop = true
        anim.isPlaying = true
        _ = scene.setComponent(anim, for: entity)

        let snapshot = SceneSemanticEncoder().encode(scene, selectedEntityID: nil,
                                                     workspaceMode: nil, localeIdentifier: nil)
        guard let record = snapshot.entities.first(where: { $0.id == "scene:\(entity.rawValue)" }) else {
            XCTFail("entity not found in snapshot"); return
        }
        XCTAssertEqual(record.audioClip,        "ambient_loop")
        XCTAssertEqual(record.audioVolume ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(record.audioLoop,        true)
        XCTAssertEqual(record.audioPlayOnAwake, false)
        XCTAssertEqual(record.animationClip,         "idle")
        XCTAssertEqual(record.animationSpeed ?? 0,   1.5, accuracy: 0.001)
        XCTAssertEqual(record.animationLoop,         true)
        XCTAssertEqual(record.animationIsPlaying,    true)
    }

    func testSceneSemanticEncoderSurfacesMeshVisibility() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RenderMeshComponent(meshIndex: 0, isVisible: false), for: entity)

        let snapshot = SceneSemanticEncoder().encode(scene, selectedEntityID: nil,
                                                     workspaceMode: nil, localeIdentifier: nil)
        guard let record = snapshot.entities.first(where: { $0.id == "scene:\(entity.rawValue)" }) else {
            XCTFail("entity not found in snapshot"); return
        }
        XCTAssertEqual(record.meshIsVisible, false)
    }

    func testSceneSemanticEncoderSurfacesPBRMaterialFields() {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        var mat = RenderMaterialComponent()
        mat.baseColorFactor = SIMD4<Float>(0.3, 0.6, 0.9, 1.0)
        mat.metallicFactor  = 0.8
        mat.roughnessFactor = 0.25
        mat.emissiveFactor  = SIMD3<Float>(0.0, 0.2, 0.4)
        _ = scene.setComponent(mat, for: entity)

        let snapshot = SceneSemanticEncoder().encode(scene, selectedEntityID: nil,
                                                     workspaceMode: nil, localeIdentifier: nil)
        guard let record = snapshot.entities.first(where: { $0.id == "scene:\(entity.rawValue)" }) else {
            XCTFail("entity not found in snapshot")
            return
        }
        XCTAssertEqual(record.materialMetallic ?? 0,  0.8,  accuracy: 0.001)
        XCTAssertEqual(record.materialRoughness ?? 0, 0.25, accuracy: 0.001)
        XCTAssertNotNil(record.materialBaseColor)
        if let bc = record.materialBaseColor {
            XCTAssertEqual(bc[0], 0.3, accuracy: 0.001)
            XCTAssertEqual(bc[1], 0.6, accuracy: 0.001)
            XCTAssertEqual(bc[2], 0.9, accuracy: 0.001)
        }
        XCTAssertNotNil(record.materialEmissive)
        if let em = record.materialEmissive {
            XCTAssertEqual(em[1], 0.2, accuracy: 0.001)
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

    func testSetMaterialExecutorProducesRenderMaterialMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RenderMaterialComponent(), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"gold","steps":[{"op":"set_material","entity_id":"\(ref)",\
        "material_base_color":[1.0,0.8,0.0,1.0],"material_metallic":0.9,"material_roughness":0.2}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasMaterial = ops.contains {
            if case let .setRenderMaterialComponent(id, base, metallic, roughness, _) = $0 {
                return id == entity.rawValue
                    && abs(base.x - 1.0) < 0.001
                    && abs(base.y - 0.8) < 0.001
                    && abs(metallic - 0.9) < 0.001
                    && abs(roughness - 0.2) < 0.001
            }
            return false
        }
        XCTAssertTrue(hasMaterial, "set_material must produce a setRenderMaterialComponent mutation")
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

    func testSessionCompactDictIncludesPBRMaterialFields() {
        var record = WorldEntityRecord(ref: "scene:42", name: "MetalBox")
        record.materialBaseColor = [0.8, 0.1, 0.1, 1.0]
        record.materialMetallic = 0.9
        record.materialRoughness = 0.2
        record.materialEmissive = [0.0, 0.5, 0.0]

        let session = Session(id: "dict-test", config: makeTestConfig())
        let dict = session.compactDict(for: record)

        XCTAssertEqual(dict["materialBaseColor"] as? [Float], [0.8, 0.1, 0.1, 1.0])
        XCTAssertEqual(dict["materialMetallic"] as? Float, 0.9)
        XCTAssertEqual(dict["materialRoughness"] as? Float, 0.2)
        XCTAssertEqual(dict["materialEmissive"] as? [Float], [0.0, 0.5, 0.0])
    }

    func testSessionCompactDictOmitsDefaultPBRMaterialFields() {
        let record = WorldEntityRecord(ref: "scene:43", name: "DefaultCube")

        let session = Session(id: "dict-test2", config: makeTestConfig())
        let dict = session.compactDict(for: record)

        XCTAssertNil(dict["materialBaseColor"])
        XCTAssertNil(dict["materialMetallic"])
        XCTAssertNil(dict["materialRoughness"])
        XCTAssertNil(dict["materialEmissive"])
    }

    func testSessionCompactDictOmitsMeshIsVisibleWhenTrue() {
        var record = WorldEntityRecord(ref: "scene:44", name: "Cube")
        record.meshIsVisible = true

        let dict = Session(id: "d3", config: makeTestConfig()).compactDict(for: record)
        XCTAssertNil(dict["meshIsVisible"], "meshIsVisible:true should be omitted to reduce prompt noise")
    }

    func testSessionCompactDictIncludesMeshIsVisibleWhenFalse() {
        var record = WorldEntityRecord(ref: "scene:45", name: "Hidden")
        record.meshIsVisible = false

        let dict = Session(id: "d4", config: makeTestConfig()).compactDict(for: record)
        XCTAssertEqual(dict["meshIsVisible"] as? Bool, false, "meshIsVisible:false must appear in compact dict")
    }

    func testSessionCompactDictIncludesColliderFields() {
        var record = WorldEntityRecord(ref: "scene:46", name: "Physics")
        record.colliderShape = "capsule"
        record.colliderIsTrigger = true
        record.colliderFriction = 0.3
        record.colliderLayerID = 5

        let dict = Session(id: "d5", config: makeTestConfig()).compactDict(for: record)
        XCTAssertEqual(dict["colliderShape"] as? String, "capsule")
        XCTAssertEqual(dict["colliderIsTrigger"] as? Bool, true)
        XCTAssertEqual(dict["colliderFriction"] as? Float, 0.3)
        XCTAssertEqual(dict["colliderLayerID"] as? Int, 5)
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

    // MARK: - find_entities agentic loop

    func testFindEntitiesResultSearchesByNameSubstring() async {
        var wv = WorldView()
        wv.apply(event: .entityAdded(ref: "scene:1", name: "Dragon Boss", kind: "Character"))
        wv.apply(event: .entityAdded(ref: "scene:2", name: "Stone Wall", kind: "Static Mesh"))
        wv.apply(event: .entityAdded(ref: "scene:3", name: "Dragon Egg", kind: "Prop"))
        let session = Session(id: "t", config: makeTestConfig(), initialWorldView: wv)

        let json = await session.findEntitiesResult(input: ["name": "dragon"])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let entities = result["entities"] as! [[String: String]]

        XCTAssertEqual(result["count"] as? Int, 2)
        XCTAssertTrue(entities.allSatisfy { $0["name"]!.lowercased().contains("dragon") })
    }

    func testFindEntitiesResultSearchesByKind() async {
        var wv = WorldView()
        wv.apply(event: .entityAdded(ref: "scene:1", name: "Main Cam", kind: "Camera"))
        wv.apply(event: .entityAdded(ref: "scene:2", name: "Ambient Light", kind: "Point Light"))
        wv.apply(event: .entityAdded(ref: "scene:3", name: "Player Camera", kind: "Camera"))
        let session = Session(id: "t", config: makeTestConfig(), initialWorldView: wv)

        let json = await session.findEntitiesResult(input: ["kind": "Camera"])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let entities = result["entities"] as! [[String: String]]

        XCTAssertEqual(result["count"] as? Int, 2)
        XCTAssertTrue(entities.allSatisfy { $0["kind"] == "Camera" })
    }

    func testFindEntitiesResultRespectsLimit() async {
        var wv = WorldView()
        for i in 1...10 {
            wv.apply(event: .entityAdded(ref: "scene:\(i)", name: "Box \(i)", kind: "Static Mesh"))
        }
        let session = Session(id: "t", config: makeTestConfig(), initialWorldView: wv)

        let json = await session.findEntitiesResult(input: ["limit": 3])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let entities = result["entities"] as! [[String: String]]

        XCTAssertEqual(entities.count, 3)
        XCTAssertEqual(result["count"] as? Int, 3)
    }

    func testFindEntitiesResultReturnsEmptyForNoMatch() async {
        var wv = WorldView()
        wv.apply(event: .entityAdded(ref: "scene:1", name: "Stone Wall", kind: "Static Mesh"))
        let session = Session(id: "t", config: makeTestConfig(), initialWorldView: wv)

        let json = await session.findEntitiesResult(input: ["name": "dragon"])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(result["count"] as? Int, 0)
        XCTAssertTrue((result["entities"] as! [[String: String]]).isEmpty)
    }

    func testSessionProcessExecutesPlanAfterFindEntitiesToolCall() async throws {
        // Simulate the agentic loop: first call returns find_entities, second returns execute_edit_plan
        let findEntitiesResponse = """
        {
          "id": "msg_1",
          "content": [
            {"type": "tool_use", "id": "tu_1", "name": "find_entities",
             "input": {"name": "dragon", "limit": 5}}
          ],
          "stop_reason": "tool_use"
        }
        """
        let editPlanResponse = """
        {
          "id": "msg_2",
          "content": [
            {"type": "tool_use", "id": "tu_2", "name": "execute_edit_plan",
             "input": {"summary": "Move dragon", "steps": []}}
          ],
          "stop_reason": "tool_use"
        }
        """
        var callCount = 0
        let responses = [findEntitiesResponse, editPlanResponse]
        MockURLProtocol.requestHandler = { _ in
            let response = responses[callCount]
            callCount += 1
            let httpResponse = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!,
                                               statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, Data(response.utf8))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        var wv = WorldView()
        wv.apply(event: .entityAdded(ref: "scene:42", name: "Dragon Boss", kind: "Character"))
        let session = Session(id: "t", config: makeTestConfig(), urlSession: mockSession,
                              initialWorldView: wv)

        let signal = Signal.naturalLanguage(text: "move the dragon forward", locale: "en")
        let proposal = try await session.process(signal)

        XCTAssertEqual(callCount, 2, "Should make exactly 2 API calls: find_entities then execute_edit_plan")
        XCTAssertEqual(proposal.plan.summary, "Move dragon")
    }

    func testSessionProcessOpenAIFormatFindEntitiesLoop() async throws {
        // OpenAI format agentic loop: find_entities followed by execute_edit_plan
        let findEntitiesResponse = """
        {
          "choices": [{
            "message": {
              "role": "assistant",
              "tool_calls": [{
                "id": "call_1",
                "type": "function",
                "function": {"name": "find_entities", "arguments": "{\\"name\\":\\"camera\\"}"}
              }]
            },
            "finish_reason": "tool_calls"
          }]
        }
        """
        let editPlanResponse = """
        {
          "choices": [{
            "message": {
              "role": "assistant",
              "tool_calls": [{
                "id": "call_2",
                "type": "function",
                "function": {"name": "execute_edit_plan",
                  "arguments": "{\\"summary\\":\\"Activate camera\\",\\"steps\\":[]}"}
              }]
            },
            "finish_reason": "tool_calls"
          }]
        }
        """
        var callCount = 0
        let responses = [findEntitiesResponse, editPlanResponse]
        MockURLProtocol.requestHandler = { _ in
            let response = responses[callCount]
            callCount += 1
            let httpResponse = HTTPURLResponse(url: URL(string: "https://api.openai.com")!,
                                               statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, Data(response.utf8))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        var wv = WorldView()
        wv.apply(event: .entityAdded(ref: "scene:7", name: "Main Camera", kind: "Camera"))
        let openAIConfig = SessionConfig.openAI(apiKey: "test")
        let session = Session(id: "t", config: openAIConfig, urlSession: mockSession,
                              initialWorldView: wv)

        let signal = Signal.naturalLanguage(text: "activate the camera", locale: "en")
        let proposal = try await session.process(signal)

        XCTAssertEqual(callCount, 2, "Should make 2 API calls: find_entities then execute_edit_plan")
        XCTAssertEqual(proposal.plan.summary, "Activate camera")
    }

    func testSessionProcessThrowsAfterExceedingFindEntitiesCallLimit() async throws {
        // After 3 find_entities calls, the loop must throw noPlanInResponse rather than looping forever
        var callCount = 0
        MockURLProtocol.requestHandler = { _ in
            callCount += 1
            let body = """
            {
              "id": "msg_\(callCount)",
              "content": [
                {"type": "tool_use", "id": "tu_\(callCount)", "name": "find_entities",
                 "input": {"name": "missing"}}
              ],
              "stop_reason": "tool_use"
            }
            """
            let httpResponse = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!,
                                               statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (httpResponse, Data(body.utf8))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        let session = Session(id: "t", config: makeTestConfig(), urlSession: mockSession)

        do {
            _ = try await session.process(Signal.naturalLanguage(text: "find the missing entity", locale: "en"))
            XCTFail("Expected noPlanInResponse error")
        } catch SessionError.noPlanInResponse {
            // Expected: 1 initial call + 3 find_entities = 4 total API calls
            XCTAssertEqual(callCount, 4, "Should make 4 calls (1 base + 3 find_entities) before giving up")
        }
    }

    func testFindEntitiesResultReturnsKindWhenPresent() async {
        var wv = WorldView()
        wv.apply(event: .entityAdded(ref: "scene:1", name: "Point Light", kind: "Light"))
        wv.apply(event: .entityAdded(ref: "scene:2", name: "Unnamed", kind: nil))
        let session = Session(id: "t", config: makeTestConfig(), initialWorldView: wv)

        let json = await session.findEntitiesResult(input: [:])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let entities = result["entities"] as! [[String: String]]

        let lightEntry = entities.first { $0["id"] == "scene:1" }!
        let unnamedEntry = entities.first { $0["id"] == "scene:2" }!
        XCTAssertEqual(lightEntry["kind"], "Light", "kind should be present when set")
        XCTAssertNil(unnamedEntry["kind"], "kind should be absent when nil")
    }

    private func makeTestConfig() -> SessionConfig {
        .anthropic(apiKey: "test")
    }

    // MARK: - WorldView recentEdits ring

    func testWorldViewRecentEditsAccumulatesAndCapsAtTwenty() {
        var view = WorldView()
        for i in 1...25 {
            view.apply(event: .editApplied(editID: "e\(i)", summary: "edit \(i)", revision: UInt64(i)))
        }
        XCTAssertEqual(view.recentEdits.count, 20, "recentEdits must cap at 20")
        // Most recent edit should be last.
        XCTAssertEqual(view.recentEdits.last?.summary, "edit 25")
        XCTAssertEqual(view.recentEdits.first?.summary, "edit 6", "oldest 5 edits must have been dropped")
    }

    func testWorldViewApplyEditSummaryConvenienceUpdatesRevisionAndRing() {
        var view = WorldView()
        view.apply(editSummary: "renamed hero", revision: 42)
        XCTAssertEqual(view.sceneRevision, 42)
        XCTAssertEqual(view.recentEdits.count, 1)
        XCTAssertEqual(view.recentEdits[0].summary, "renamed hero")
        XCTAssertEqual(view.recentEdits[0].revision, 42)
    }

    func testWorldViewSelectionChangedMarksIsSelectedOnRecords() {
        var view = WorldView()
        view.apply(event: .entityAdded(ref: "scene:1", name: "A", kind: nil))
        view.apply(event: .entityAdded(ref: "scene:2", name: "B", kind: nil))
        view.apply(event: .selectionChanged(refs: ["scene:1"]))
        XCTAssertEqual(view.entityIndex["scene:1"]?.isSelected, true)
        XCTAssertEqual(view.entityIndex["scene:2"]?.isSelected, false)
        XCTAssertEqual(view.selectedEntityRefs, ["scene:1"])
    }

    func testWorldViewApplySelectionChangedConvenienceWrapper() {
        var view = WorldView()
        view.apply(event: .entityAdded(ref: "scene:5", name: "X", kind: nil))
        view.apply(selectionChanged: ["scene:5"])
        XCTAssertTrue(view.entityIndex["scene:5"]?.isSelected ?? false)
        XCTAssertEqual(view.selectedEntityRefs, ["scene:5"])
    }

    func testWorldViewEntityRemovedClearsFromSelection() {
        var view = WorldView()
        view.apply(event: .entityAdded(ref: "scene:3", name: "C", kind: nil))
        view.apply(event: .selectionChanged(refs: ["scene:3"]))
        view.apply(event: .entityRemoved(ref: "scene:3"))
        XCTAssertNil(view.entityIndex["scene:3"])
        XCTAssertFalse(view.selectedEntityRefs.contains("scene:3"))
    }

    func testWorldViewWorkflowModeSetFromSnapshot() {
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:1", name: "E", kind: "Entity",
            parentRef: nil, childRefs: [], isSelected: false,
            position: nil, components: []
        )
        let snapshot = SceneSemanticSnapshot(
            sceneRevision: 7, entityCount: 1, entities: [entity],
            workspaceMode: "animation"
        )
        var view = WorldView()
        view.apply(snapshot: snapshot)
        XCTAssertEqual(view.workflowMode, "animation")
        XCTAssertEqual(view.sceneRevision, 7)
    }

    // MARK: - Session observation wrappers

    func testSessionObserveSnapshotUpdatesWorldView() async {
        let session = Session(id: "obs1", config: makeTestConfig())
        let entity = SceneSemanticSnapshot.Entity(
            id: "scene:77", name: "Boulder", kind: "mesh",
            parentRef: nil, childRefs: [], isSelected: false,
            position: [1, 2, 3], components: ["transform", "mesh"]
        )
        await session.observe(snapshot: SceneSemanticSnapshot(sceneRevision: 5, entityCount: 1, entities: [entity]))
        let record = await session.entityRecord(ref: "scene:77")
        XCTAssertEqual(record?.name, "Boulder")
        XCTAssertEqual(record?.position, [1, 2, 3])
    }

    func testSessionObserveSelectionChangedUpdatesWorldView() async {
        let session = Session(id: "obs2", config: makeTestConfig())
        await session.observe(event: .entityAdded(ref: "scene:10", name: "Player", kind: "mesh"))
        await session.observe(selectionChanged: ["scene:10"])
        let record = await session.entityRecord(ref: "scene:10")
        XCTAssertEqual(record?.isSelected, true)
        let view = await session.worldViewSnapshot()
        XCTAssertEqual(view.selectedEntityRefs, ["scene:10"])
    }

    func testSessionObserveEditSummaryUpdatesRevisionAndTriggersFlush() async throws {
        let session = Session(id: "obs3", config: makeTestConfig())
        let store = try ContextMemoryStore()
        await session.setContextMemory(store)
        await session.observe(editSummary: "rotated cube", revision: 99)
        let view = await session.worldViewSnapshot()
        XCTAssertEqual(view.sceneRevision, 99)
        XCTAssertEqual(view.recentEdits.first?.summary, "rotated cube")
    }

    func testSessionHistorySnapshotReflectsRecordedTurns() async {
        let session = Session(id: "hist1", config: makeTestConfig())
        await session.recordTurn(ConversationTurn(kind: .userText("hello")))
        let history = await session.historySnapshot()
        XCTAssertEqual(history.count, 1)
        if case let .userText(t) = history[0].kind {
            XCTAssertEqual(t, "hello")
        } else {
            XCTFail("Expected userText turn")
        }
    }

    func testSessionWorldViewSnapshotReturnsCurrentState() async {
        let session = Session(id: "snap1", config: makeTestConfig())
        await session.observe(event: .entityAdded(ref: "scene:20", name: "Camera", kind: "camera"))
        let view = await session.worldViewSnapshot()
        XCTAssertNotNil(view.entityIndex["scene:20"])
    }

    // MARK: - findEntitiesResult combined filter

    func testFindEntitiesResultCombinesNameAndKindFilter() async {
        var wv = WorldView()
        wv.apply(event: .entityAdded(ref: "scene:1", name: "Dragon Boss", kind: "Character"))
        wv.apply(event: .entityAdded(ref: "scene:2", name: "Dragon Scale", kind: "Prop"))
        wv.apply(event: .entityAdded(ref: "scene:3", name: "Small Dragon", kind: "Character"))
        wv.apply(event: .entityAdded(ref: "scene:4", name: "Stone Wall",   kind: "Static Mesh"))
        let session = Session(id: "cmb", config: makeTestConfig(), initialWorldView: wv)

        let json = await session.findEntitiesResult(input: ["name": "dragon", "kind": "Character"])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let entities = result["entities"] as! [[String: String]]

        XCTAssertEqual(result["count"] as? Int, 2, "only 'Dragon Boss' and 'Small Dragon' match both filters")
        XCTAssertTrue(entities.allSatisfy { $0["kind"] == "Character" })
        XCTAssertTrue(entities.allSatisfy { $0["name"]!.lowercased().contains("dragon") })
    }

    // MARK: - AIWorldContext.discardSnapshot / replaceWorldView

    func testAIWorldContextDiscardSnapshotRemovesEntry() async throws {
        let context = AIWorldContext()
        await context.observe(event: .entityAdded(ref: "scene:1", name: "A", kind: nil))
        let (id, _) = try await context.materializeSnapshot(scope: "scene")
        let before = await context.worldViewForSnapshot(snapshotID: id)
        XCTAssertNotNil(before)
        await context.discardSnapshot(snapshotID: id)
        let after = await context.worldViewForSnapshot(snapshotID: id)
        XCTAssertNil(after, "discarded snapshot must not be retrievable")
    }

    func testAIWorldContextReplaceWorldViewReplacesState() async throws {
        let context = AIWorldContext()
        await context.observe(event: .entityAdded(ref: "scene:1", name: "Old", kind: nil))

        var freshView = WorldView()
        freshView.apply(event: .entityAdded(ref: "scene:99", name: "New", kind: nil))
        await context.replaceWorldView(freshView)

        let record = await context.entityRecord(ref: "scene:99")
        XCTAssertNotNil(record, "replaced WorldView entity should be accessible")
        let oldRecord = await context.entityRecord(ref: "scene:1")
        XCTAssertNil(oldRecord, "old entity must no longer be accessible after replaceWorldView")
    }

    func testAIWorldContextReplaceWorldViewAdvancesRevision() async throws {
        let context = AIWorldContext()
        let (_, cur1) = try await context.materializeSnapshot(scope: "scene")
        var view = WorldView()
        view.apply(event: .entityAdded(ref: "scene:1", name: "X", kind: nil))
        await context.replaceWorldView(view)
        let (_, cur2) = try await context.materializeSnapshot(scope: "scene")
        XCTAssertLessThan(cur1.seq, cur2.seq, "revision must advance after replaceWorldView")
    }

    // MARK: - WorkflowContext prompt extras

    func testGameWorkflowContextIncludesScriptingRegistryInPrompt() {
        let constraints = GameKnownConstraints(
            navMeshBaked: false,
            performanceBudget: "console_high",
            scriptingRegistry: ["patrol", "attack", "flee"]
        )
        let ctx = GameWorkflowContext(
            levelPhase: .blockout,
            gameplayIntent: GameplayIntent(genre: "rpg", winCondition: "defeat_boss"),
            targetExperience: "tense combat",
            knownConstraints: constraints
        )
        let section = ctx.systemPromptSection
        XCTAssertTrue(section.contains("patrol"))
        XCTAssertTrue(section.contains("attack"))
        XCTAssertTrue(section.contains("flee"))
    }

    func testGameWorkflowContextIncludesNavMeshNoteWhenBaked() {
        let constraints = GameKnownConstraints(navMeshBaked: true, performanceBudget: "pc_ultra")
        let ctx = GameWorkflowContext(
            levelPhase: .encounterDesign,
            gameplayIntent: GameplayIntent(genre: "stealth", winCondition: "escape"),
            targetExperience: "tense sneaking",
            knownConstraints: constraints
        )
        let section = ctx.systemPromptSection
        XCTAssertTrue(section.contains("NavMesh") || section.contains("traversability"))
    }

    func testGameWorkflowContextOmitsNavMeshNoteWhenNotBaked() {
        let ctx = GameWorkflowContext(
            levelPhase: .polish,
            gameplayIntent: GameplayIntent(genre: "puzzle", winCondition: "solve_all"),
            targetExperience: "calm",
            knownConstraints: GameKnownConstraints(navMeshBaked: false)
        )
        XCTAssertFalse(ctx.systemPromptSection.contains("NavMesh"))
    }

    func testGameWorkflowContextIncludesPerformanceBudgetInPrompt() {
        let constraints = GameKnownConstraints(navMeshBaked: false, performanceBudget: "mobile_low")
        let ctx = GameWorkflowContext(
            levelPhase: .blockout,
            gameplayIntent: GameplayIntent(genre: "platformer", winCondition: "reach_end"),
            targetExperience: "casual",
            knownConstraints: constraints
        )
        XCTAssertTrue(ctx.systemPromptSection.contains("mobile_low"),
                      "performance budget should appear in system prompt section")
    }

    func testGameWorkflowContextIncludesPlayerCountInPrompt() {
        let ctx = GameWorkflowContext(
            levelPhase: .blockout,
            gameplayIntent: GameplayIntent(genre: "co-op", winCondition: "survive",
                                           playerCount: 4, pacing: "action"),
            targetExperience: "chaotic fun"
        )
        XCTAssertTrue(ctx.systemPromptSection.contains("4"),
                      "player count should appear in system prompt section")
    }

    // MARK: - Locale propagation

    func testSessionNaturalLanguageWithNonEnglishLocaleProducesProposal() async throws {
        let planResponse = """
        {
          "id": "msg_l1",
          "content": [
            {"type": "tool_use", "id": "tu_l1", "name": "execute_edit_plan",
             "input": {"summary": "场景编辑完成", "steps": []}}
          ],
          "stop_reason": "tool_use"
        }
        """
        MockURLProtocol.requestHandler = { _ in
            let http = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(planResponse.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = Session(id: "locale1", config: makeTestConfig(), urlSession: URLSession(configuration: config))

        let proposal = try await session.process(Signal.naturalLanguage(
            text: "将所有灯光颜色改为暖白色",
            locale: "zh-Hans"
        ))
        XCTAssertNotNil(proposal.id, "non-English locale signal must still produce a Proposal")
        XCTAssertEqual(proposal.plan.summary, "场景编辑完成")
    }

    // MARK: - Session.process(.userCorrection) all-accepted path

    func testSessionProcessUserCorrectionAllAcceptedReturnsNoopProposal() async throws {
        // Given a session with a prior tool call turn in history
        let session = Session(id: "corr1", config: makeTestConfig())
        await session.recordTurn(ConversationTurn(kind: .userText("add a cube")))
        await session.recordTurn(ConversationTurn(kind: .assistantToolCall(
            toolUseID: "tu_1",
            name: "execute_edit_plan",
            inputJSON: "{\"summary\":\"Added cube\",\"steps\":[]}"
        )))

        // When: correction with no rejections (all accepted)
        let signal = Signal.userCorrection(
            proposalID: "prop_1",
            acceptedStepIDs: ["step_1"],
            rejectedStepIDs: []
        )
        let proposal = try await session.process(signal)

        // Then: returns empty plan with automatic approval and no additional API call
        XCTAssertTrue(proposal.plan.steps.isEmpty, "all-accepted correction produces empty plan")
        XCTAssertEqual(proposal.approvalPolicy, .automatic)
    }

    func testSessionProcessUserCorrectionRecordsToolResultInHistory() async throws {
        let session = Session(id: "corr2", config: makeTestConfig())
        await session.recordTurn(ConversationTurn(kind: .userText("move the cube")))
        await session.recordTurn(ConversationTurn(kind: .assistantToolCall(
            toolUseID: "tu_2",
            name: "execute_edit_plan",
            inputJSON: "{\"summary\":\"Moved cube\",\"steps\":[]}"
        )))

        let signal = Signal.userCorrection(
            proposalID: "prop_2",
            acceptedStepIDs: ["step_1"],
            rejectedStepIDs: []
        )
        _ = try await session.process(signal)

        let history = await session.historySnapshot()
        let hasToolResult = history.contains {
            if case let .toolResult(id, _) = $0.kind { return id == "tu_2" }
            return false
        }
        XCTAssertTrue(hasToolResult, "processing a correction must record a toolResult for the prior call's toolUseID")
    }

    func testSessionProcessUserCorrectionRejectedRecordsPlanOpsInContextMemory() async throws {
        let planJSON = "{\"summary\":\"Renamed cube\",\"steps\":[{\"op\":\"set_name\",\"entity_id\":\"scene:1\",\"name\":\"New\"}]}"
        let planResponse = """
        {
          "id": "msg_r1",
          "content": [
            {"type": "tool_use", "id": "tu_r1", "name": "execute_edit_plan",
             "input": {"summary": "Revised.", "steps": []}}
          ],
          "stop_reason": "tool_use"
        }
        """
        MockURLProtocol.requestHandler = { _ in
            let http = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(planResponse.utf8))
        }
        let urlConfig = URLSessionConfiguration.ephemeral
        urlConfig.protocolClasses = [MockURLProtocol.self]
        let mem = try ContextMemoryStore()
        let session = Session(id: "mem-corr", config: makeTestConfig(), urlSession: URLSession(configuration: urlConfig))
        await session.setContextMemory(mem)
        await session.recordTurn(ConversationTurn(kind: .userText("rename the cube")))
        await session.recordTurn(ConversationTurn(kind: .assistantToolCall(
            toolUseID: "tu_r0", name: "execute_edit_plan", inputJSON: planJSON
        )))

        _ = try await session.process(Signal.userCorrection(
            proposalID: "prop_r1",
            acceptedStepIDs: [],
            rejectedStepIDs: ["step_0"]
        ))

        // Allow the async Task { await mem.upsert } to complete
        try await Task.sleep(nanoseconds: 10_000_000)

        let entry = await mem.entry(id: "pref:rejected:prop_r1")
        XCTAssertNotNil(entry, "rejected correction must produce a userPreference entry")
        XCTAssertEqual(entry?.payload["plan_ops"], "set_name",
                       "plan_ops must contain the operation type from the rejected plan")
        XCTAssertEqual(entry?.payload["plan_summary"], "Renamed cube",
                       "plan_summary must capture the plan summary")
    }

    // MARK: - Executor error paths (missingEntityRef, entityNotFound, invalidEntityRef, invalidColor)

    func testExecutorThrowsMissingEntityRefForDeleteEntity() throws {
        var scene = SceneRuntime()
        _ = scene.createEntity()

        let json = """
        {"summary":"del","steps":[{"op":"delete_entity"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        XCTAssertThrowsError(try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)) { err in
            if case SceneEditPlanExecutorError.missingEntityRef(let op) = err {
                XCTAssertEqual(op, .deleteEntity)
            } else {
                XCTFail("expected missingEntityRef, got \(err)")
            }
        }
    }

    func testExecutorThrowsEntityNotFoundForNonexistentRef() throws {
        var scene = SceneRuntime()
        _ = scene.createEntity()

        let json = """
        {"summary":"del","steps":[{"op":"delete_entity","entity_id":"scene:99999"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        XCTAssertThrowsError(try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)) { err in
            if case SceneEditPlanExecutorError.entityNotFound(let ref) = err {
                XCTAssertEqual(ref, "scene:99999")
            } else {
                XCTFail("expected entityNotFound, got \(err)")
            }
        }
    }

    func testExecutorThrowsInvalidEntityRefForMalformedRef() throws {
        var scene = SceneRuntime()
        _ = scene.createEntity()

        let json = """
        {"summary":"bad","steps":[{"op":"delete_entity","entity_id":"invalid-format"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        XCTAssertThrowsError(try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)) { err in
            if case SceneEditPlanExecutorError.invalidEntityRef(let ref) = err {
                XCTAssertEqual(ref, "invalid-format")
            } else {
                XCTFail("expected invalidEntityRef, got \(err)")
            }
        }
    }

    func testExecutorThrowsInvalidColorForShortColorArray() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(RenderMeshComponent(meshIndex: 0), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"bad color","steps":[{"op":"set_mesh_color","entity_id":"\(ref)","color":[1.0,0.5]}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        XCTAssertThrowsError(try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)) { err in
            if case SceneEditPlanExecutorError.invalidColor(let op) = err {
                XCTAssertEqual(op, .setMeshColor)
            } else {
                XCTFail("expected invalidColor, got \(err)")
            }
        }
    }

    func testExecutorThrowsMissingFieldForSetLightRangeWithoutRange() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(LightComponent(type: .point, color: .one, intensity: 100, range: 10), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"range","steps":[{"op":"set_light_range","entity_id":"\(ref)"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        XCTAssertThrowsError(try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)) { err in
            if case SceneEditPlanExecutorError.missingField(_, let field) = err {
                XCTAssertEqual(field, "range")
            } else {
                XCTFail("expected missingField(range), got \(err)")
            }
        }
    }

    func testExecutorThrowsMissingFieldForSetColliderLayerWithNoFields() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: .box(halfExtents: .one, center: .zero)), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"layer","steps":[{"op":"set_collider_layer","entity_id":"\(ref)"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        XCTAssertThrowsError(try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)) { err in
            if case SceneEditPlanExecutorError.missingField = err { } else {
                XCTFail("expected missingField, got \(err)")
            }
        }
    }

    // MARK: - entityEvaluatedChanged event

    func testEntityEvaluatedChangedPopulatesEvaluatedDict() {
        var view = WorldView()
        view.apply(event: .entityAdded(ref: "scene:1", name: "A", kind: nil))
        view.apply(event: .entityEvaluatedChanged(ref: "scene:1",
                                                   property: "worldPosition",
                                                   value: .vec3(10, 20, 30)))
        XCTAssertEqual(view.entityIndex["scene:1"]?.evaluated["worldPosition"], .vec3(10, 20, 30))
    }

    func testEntityEvaluatedChangedCreatesRecordWhenEntityAbsent() {
        var view = WorldView()
        view.apply(event: .entityEvaluatedChanged(ref: "scene:9",
                                                   property: "worldScale",
                                                   value: .vec3(2, 2, 2)))
        XCTAssertEqual(view.entityIndex["scene:9"]?.evaluated["worldScale"], .vec3(2, 2, 2))
    }

    // MARK: - setColliderShape with mesh / convex kinds

    func testSetColliderShapeMeshKindProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: .box(halfExtents: .one, center: .zero)), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"mesh collider","steps":[{"op":"set_collider_shape","entity_id":"\(ref)","collider_shape":"mesh"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)
        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let has = ops.contains { if case .setColliderShapeType(_, .mesh) = $0 { return true }; return false }
        XCTAssertTrue(has, "set_collider_shape 'mesh' must produce setColliderShapeType(.mesh)")
    }

    func testSetColliderShapeConvexKindProducesMutation() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        _ = scene.setComponent(Collider(shape: .box(halfExtents: .one, center: .zero)), for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"convex","steps":[{"op":"set_collider_shape","entity_id":"\(ref)","collider_shape":"convex"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)
        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let has = ops.contains { if case .setColliderShapeType(_, .convex) = $0 { return true }; return false }
        XCTAssertTrue(has, "set_collider_shape 'convex' must produce setColliderShapeType(.convex)")
    }

    // MARK: - Session.process(.referenceImage)

    func testSessionProcessReferenceImageReturnsProposal() async throws {
        let planResponse = """
        {
          "id": "msg_1",
          "content": [
            {"type": "tool_use", "id": "tu_1", "name": "execute_edit_plan",
             "input": {"summary": "Created entity from reference.", "steps": []}}
          ],
          "stop_reason": "tool_use"
        }
        """
        MockURLProtocol.requestHandler = { _ in
            let http = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(planResponse.utf8))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = Session(id: "img1", config: makeTestConfig(), urlSession: URLSession(configuration: config))
        let signal = Signal.referenceImage(url: URL(fileURLWithPath: "/tmp/ref.png"), entityRef: "scene:1")
        let proposal = try await session.process(signal)

        XCTAssertEqual(proposal.plan.summary, "Created entity from reference.")
    }

    func testSessionProcessReferenceImageRecordsUserTurnWithFilenameAndEntityRef() async throws {
        let planResponse = """
        {
          "id": "msg_1",
          "content": [
            {"type": "tool_use", "id": "tu_1", "name": "execute_edit_plan",
             "input": {"summary": "Named entity.", "steps": []}}
          ],
          "stop_reason": "tool_use"
        }
        """
        MockURLProtocol.requestHandler = { _ in
            let http = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (http, Data(planResponse.utf8))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = Session(id: "img2", config: makeTestConfig(), urlSession: URLSession(configuration: config))
        _ = try await session.process(Signal.referenceImage(
            url: URL(fileURLWithPath: "/tmp/chair.jpg"),
            entityRef: "scene:5"
        ))

        // The user message is recorded in conversationHistory — check it via historySnapshot.
        let history = await session.historySnapshot()
        let userTexts = history.compactMap { turn -> String? in
            if case let .userText(t) = turn.kind { return t }; return nil
        }
        let userMessage = try XCTUnwrap(userTexts.first)
        XCTAssertTrue(userMessage.contains("chair.jpg"), "filename must appear in recorded user message")
        XCTAssertTrue(userMessage.contains("scene:5"),   "entity ref must appear in recorded user message")
    }

    // MARK: - setMaterial read-modify-write

    func testSetMaterialPreservesExistingFieldsWhenOnlyRoughnessSpecified() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        var mat = RenderMaterialComponent()
        mat.baseColorFactor = SIMD4<Float>(0.2, 0.4, 0.6, 1.0)
        mat.metallicFactor = 0.8
        mat.roughnessFactor = 0.9
        _ = scene.setComponent(mat, for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"rough","steps":[{"op":"set_material","entity_id":"\(ref)","material_roughness":0.1}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let ok = ops.contains {
            if case let .setRenderMaterialComponent(id, base, metallic, roughness, _) = $0 {
                return id == entity.rawValue
                    && abs(base.x - 0.2) < 0.001   // preserved
                    && abs(base.y - 0.4) < 0.001   // preserved
                    && abs(base.z - 0.6) < 0.001   // preserved
                    && abs(metallic - 0.8) < 0.001 // preserved
                    && abs(roughness - 0.1) < 0.001 // updated
            }
            return false
        }
        XCTAssertTrue(ok, "set_material must preserve existing base color and metallic when only roughness is specified")
    }

    func testSetMaterialPreservesExistingFieldsWhenOnlyMetallicSpecified() throws {
        var scene = SceneRuntime()
        let entity = scene.createEntity()
        var mat = RenderMaterialComponent()
        mat.baseColorFactor = SIMD4<Float>(1.0, 0.0, 0.0, 1.0)
        mat.roughnessFactor = 0.3
        _ = scene.setComponent(mat, for: entity)
        let ref = "scene:\(entity.rawValue)"

        let json = """
        {"summary":"metal","steps":[{"op":"set_material","entity_id":"\(ref)","material_metallic":1.0}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)

        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let ok = ops.contains {
            if case let .setRenderMaterialComponent(id, base, metallic, roughness, _) = $0 {
                return id == entity.rawValue
                    && abs(base.x - 1.0) < 0.001   // preserved
                    && abs(base.z - 0.0) < 0.001   // preserved
                    && abs(metallic - 1.0) < 0.001  // updated
                    && abs(roughness - 0.3) < 0.001 // preserved
            }
            return false
        }
        XCTAssertTrue(ok, "set_material must preserve existing roughness when only metallic is specified")
    }

    // MARK: - audioPitch / audioSpatialBlend snapshot pipeline

    func testSnapshotEntityIncludesAudioPitchWhenNonDefault() {
        var snap = SceneSemanticSnapshot.Entity(
            id: "scene:1", name: "SFX", kind: "Entity",
            parentRef: nil, childRefs: [],
            isSelected: false,
            position: nil, scale: nil, eulerDegrees: nil,
            worldPosition: nil, worldEulerDegrees: nil, worldScale: nil,
            components: ["audio_source"],
            audioVolume: 0.8,
            audioPitch: 1.5
        )
        _ = snap  // already verified by construction; test the field round-trips through WorldView

        var wv = WorldView()
        let full = SceneSemanticSnapshot(
            sceneRevision: 1, entityCount: 1, entities: [snap],
            selectedRef: nil, workspaceMode: nil, localeIdentifier: nil
        )
        wv.apply(snapshot: full)
        XCTAssertEqual(wv.entityIndex["scene:1"]?.audioPitch, 1.5)
    }

    func testSnapshotEntityIncludesAudioSpatialBlend() {
        let snap = SceneSemanticSnapshot.Entity(
            id: "scene:2", name: "Speaker", kind: "Entity",
            parentRef: nil, childRefs: [],
            isSelected: false,
            position: nil, scale: nil, eulerDegrees: nil,
            worldPosition: nil, worldEulerDegrees: nil, worldScale: nil,
            components: ["audio_source"],
            audioVolume: 1.0,
            audioSpatialBlend: 0.75
        )
        var wv = WorldView()
        let full = SceneSemanticSnapshot(
            sceneRevision: 2, entityCount: 1, entities: [snap],
            selectedRef: nil, workspaceMode: nil, localeIdentifier: nil
        )
        wv.apply(snapshot: full)
        XCTAssertEqual(wv.entityIndex["scene:2"]?.audioSpatialBlend, 0.75)
    }

    func testWorldEntityRecordApplyAudioPitchEvent() {
        var record = WorldEntityRecord(ref: "scene:3")
        record.apply(property: "audioPitch", value: .float(0.5))
        XCTAssertEqual(record.audioPitch, 0.5)
    }

    func testWorldEntityRecordApplyAudioSpatialBlendEvent() {
        var record = WorldEntityRecord(ref: "scene:4")
        record.apply(property: "audioSpatialBlend", value: .float(0.9))
        XCTAssertEqual(record.audioSpatialBlend, 0.9)
    }

    func testCompactDictIncludesAudioPitchAndSpatialBlend() {
        var record = WorldEntityRecord(ref: "scene:50", name: "BGM")
        record.audioPitch = 1.25
        record.audioSpatialBlend = 0.6
        let dict = Session(id: "audio-dict", config: makeTestConfig()).compactDict(for: record)
        XCTAssertEqual(dict["audioPitch"] as? Float, 1.25)
        XCTAssertEqual(dict["audioSpatialBlend"] as? Float, 0.6)
    }

    func testCompactDictOmitsAudioPitchAndSpatialBlendWhenNil() {
        let record = WorldEntityRecord(ref: "scene:51", name: "Silent")
        let dict = Session(id: "audio-dict2", config: makeTestConfig()).compactDict(for: record)
        XCTAssertNil(dict["audioPitch"])
        XCTAssertNil(dict["audioSpatialBlend"])
    }

    // MARK: - WorldEntityRecord.components snapshot pipeline

    func testWorldViewApplySnapshotPreservesComponentsList() {
        let snap = SceneSemanticSnapshot.Entity(
            id: "scene:1", name: "Lamp", kind: "Point Light",
            parentRef: nil, childRefs: [],
            isSelected: false,
            position: nil, scale: nil, eulerDegrees: nil,
            worldPosition: nil, worldEulerDegrees: nil, worldScale: nil,
            components: ["transform", "light"]
        )
        var wv = WorldView()
        wv.apply(snapshot: SceneSemanticSnapshot(
            sceneRevision: 1, entityCount: 1, entities: [snap],
            selectedRef: nil, workspaceMode: nil, localeIdentifier: nil
        ))
        XCTAssertEqual(wv.entityIndex["scene:1"]?.components, ["transform", "light"])
    }

    func testCompactDictIncludesComponentsWhenNonEmpty() {
        var record = WorldEntityRecord(ref: "scene:60", name: "Camera")
        record.components = ["transform", "camera"]
        let dict = Session(id: "comp-dict", config: makeTestConfig()).compactDict(for: record)
        XCTAssertEqual(dict["components"] as? [String], ["transform", "camera"])
    }

    func testCompactDictOmitsComponentsWhenEmpty() {
        let record = WorldEntityRecord(ref: "scene:61", name: "Empty")
        let dict = Session(id: "comp-dict2", config: makeTestConfig()).compactDict(for: record)
        XCTAssertNil(dict["components"])
    }

    // MARK: - find_entities component filter

    func testFindEntitiesComponentFilterMatchesCorrectEntities() async {
        var wv = WorldView()
        let lightSnap = SceneSemanticSnapshot.Entity(
            id: "scene:1", name: "Sun Light", kind: "Directional Light",
            parentRef: nil, childRefs: [],
            isSelected: false,
            position: nil, scale: nil, eulerDegrees: nil,
            worldPosition: nil, worldEulerDegrees: nil, worldScale: nil,
            components: ["transform", "light"]
        )
        let meshSnap = SceneSemanticSnapshot.Entity(
            id: "scene:2", name: "Rock", kind: "Static Mesh",
            parentRef: nil, childRefs: [],
            isSelected: false,
            position: nil, scale: nil, eulerDegrees: nil,
            worldPosition: nil, worldEulerDegrees: nil, worldScale: nil,
            components: ["transform", "mesh"]
        )
        let camSnap = SceneSemanticSnapshot.Entity(
            id: "scene:3", name: "Main Camera", kind: "Camera",
            parentRef: nil, childRefs: [],
            isSelected: false,
            position: nil, scale: nil, eulerDegrees: nil,
            worldPosition: nil, worldEulerDegrees: nil, worldScale: nil,
            components: ["transform", "camera"]
        )
        wv.apply(snapshot: SceneSemanticSnapshot(
            sceneRevision: 1, entityCount: 3, entities: [lightSnap, meshSnap, camSnap],
            selectedRef: nil, workspaceMode: nil, localeIdentifier: nil
        ))
        let session = Session(id: "comp-filter", config: makeTestConfig(), initialWorldView: wv)

        let json = await session.findEntitiesResult(input: ["component": "light"])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]

        XCTAssertEqual(result["count"] as? Int, 1)
        let entities = result["entities"] as! [[String: Any]]
        XCTAssertEqual(entities.first?["id"] as? String, "scene:1")
    }

    func testFindEntitiesComponentFilterCaseInsensitive() async {
        var wv = WorldView()
        let snap = SceneSemanticSnapshot.Entity(
            id: "scene:1", name: "Walker", kind: "Character",
            parentRef: nil, childRefs: [],
            isSelected: false,
            position: nil, scale: nil, eulerDegrees: nil,
            worldPosition: nil, worldEulerDegrees: nil, worldScale: nil,
            components: ["transform", "animation", "script"]
        )
        wv.apply(snapshot: SceneSemanticSnapshot(
            sceneRevision: 1, entityCount: 1, entities: [snap],
            selectedRef: nil, workspaceMode: nil, localeIdentifier: nil
        ))
        let session = Session(id: "comp-ci", config: makeTestConfig(), initialWorldView: wv)

        let json = await session.findEntitiesResult(input: ["component": "Animation"])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(result["count"] as? Int, 1, "component filter must be case-insensitive")
    }

    func testFindEntitiesResultIncludesComponentsArrayInOutput() async {
        var wv = WorldView()
        let snap = SceneSemanticSnapshot.Entity(
            id: "scene:1", name: "Player", kind: "Character",
            parentRef: nil, childRefs: [],
            isSelected: false,
            position: nil, scale: nil, eulerDegrees: nil,
            worldPosition: nil, worldEulerDegrees: nil, worldScale: nil,
            components: ["transform", "rigidbody", "script"]
        )
        wv.apply(snapshot: SceneSemanticSnapshot(
            sceneRevision: 1, entityCount: 1, entities: [snap],
            selectedRef: nil, workspaceMode: nil, localeIdentifier: nil
        ))
        let session = Session(id: "comp-out", config: makeTestConfig(), initialWorldView: wv)

        let json = await session.findEntitiesResult(input: [:])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let entities = result["entities"] as! [[String: Any]]

        let comps = entities.first?["components"] as? [String]
        XCTAssertEqual(comps, ["transform", "rigidbody", "script"],
                       "components array must appear in findEntities output")
    }

    func testFindEntitiesResultIncludesPositionWhenAvailable() async {
        var wv = WorldView()
        let snap = SceneSemanticSnapshot.Entity(
            id: "scene:1", name: "Chest", kind: "Prop",
            parentRef: nil, childRefs: [],
            isSelected: false,
            position: [3.0, 0.0, -5.0],
            scale: nil, eulerDegrees: nil,
            worldPosition: [3.0, 0.0, -5.0],
            worldEulerDegrees: nil, worldScale: nil,
            components: ["transform"]
        )
        wv.apply(snapshot: SceneSemanticSnapshot(
            sceneRevision: 1, entityCount: 1, entities: [snap],
            selectedRef: nil, workspaceMode: nil, localeIdentifier: nil
        ))
        let session = Session(id: "pos-find", config: makeTestConfig(), initialWorldView: wv)

        let json = await session.findEntitiesResult(input: [:])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let entities = result["entities"] as! [[String: Any]]

        let pos = entities.first?["position"] as? [Float]
        XCTAssertEqual(pos, [3.0, 0.0, -5.0], "position must appear in findEntities output")
        let worldPos = entities.first?["worldPosition"] as? [Float]
        XCTAssertNotNil(worldPos, "worldPosition must appear in findEntities output when available")
    }

    func testFindEntitiesResultIncludesParentRefWhenPresent() async {
        var wv = WorldView()
        let childSnap = SceneSemanticSnapshot.Entity(
            id: "scene:2", name: "Child", kind: "Entity",
            parentRef: "scene:1", childRefs: [],
            isSelected: false,
            position: nil, scale: nil, eulerDegrees: nil,
            worldPosition: nil, worldEulerDegrees: nil, worldScale: nil,
            components: []
        )
        wv.apply(snapshot: SceneSemanticSnapshot(
            sceneRevision: 1, entityCount: 1, entities: [childSnap],
            selectedRef: nil, workspaceMode: nil, localeIdentifier: nil
        ))
        let session = Session(id: "parent-find", config: makeTestConfig(), initialWorldView: wv)

        let json = await session.findEntitiesResult(input: [:])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let entities = result["entities"] as! [[String: Any]]

        XCTAssertEqual(entities.first?["parentRef"] as? String, "scene:1",
                       "parentRef must appear in findEntities output when the entity has a parent")
    }

    // MARK: - spawn_kind support

    func testSpawnKindEmptyProducesSpawnEmptyEntityMutation() throws {
        let scene = SceneRuntime()
        let json = """
        {"summary":"group","steps":[{"op":"spawn_entity","label":"Group","spawn_kind":"empty","spawn_position":[1,0,0]}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)
        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasEmpty = ops.contains {
            if case let .spawnEmptyEntity(label, pos) = $0 {
                return label == "Group" && abs(pos.x - 1) < 0.01
            }
            return false
        }
        XCTAssertTrue(hasEmpty, "spawn_kind 'empty' must produce spawnEmptyEntity mutation")
    }

    func testSpawnKindLightProducesSpawnLightEntityMutation() throws {
        let scene = SceneRuntime()
        let json = """
        {"summary":"light","steps":[{"op":"spawn_entity","label":"Fill Light","spawn_kind":"light","light_type":"point","spawn_position":[0,3,0]}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)
        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasLight = ops.contains {
            if case let .spawnLightEntity(label, lt, pos) = $0 {
                return label == "Fill Light" && lt == .point && abs(pos.y - 3) < 0.01
            }
            return false
        }
        XCTAssertTrue(hasLight, "spawn_kind 'light' must produce spawnLightEntity mutation with correct type and position")
    }

    func testSpawnKindLightDefaultsToPointWhenLightTypeOmitted() throws {
        let scene = SceneRuntime()
        let json = """
        {"summary":"light","steps":[{"op":"spawn_entity","label":"Key","spawn_kind":"light"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)
        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasPointLight = ops.contains {
            if case let .spawnLightEntity(_, lt, _) = $0 { return lt == .point }
            return false
        }
        XCTAssertTrue(hasPointLight, "spawn_kind 'light' with no light_type should default to point light")
    }

    func testSpawnKindCameraProducesSpawnCameraEntityMutation() throws {
        let scene = SceneRuntime()
        let json = """
        {"summary":"cam","steps":[{"op":"spawn_entity","label":"Security Cam","spawn_kind":"camera","spawn_position":[5,2,-3]}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)
        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasCam = ops.contains {
            if case let .spawnCameraEntity(label, pos) = $0 {
                return label == "Security Cam" && abs(pos.x - 5) < 0.01
            }
            return false
        }
        XCTAssertTrue(hasCam, "spawn_kind 'camera' must produce spawnCameraEntity mutation")
    }

    func testSpawnKindMeshIsDefaultWhenOmitted() throws {
        let scene = SceneRuntime()
        let json = """
        {"summary":"mesh","steps":[{"op":"spawn_entity","label":"Box"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)
        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasMesh = ops.contains { if case .spawnImportedMeshEntity = $0 { return true }; return false }
        XCTAssertTrue(hasMesh, "spawn_entity with no spawn_kind must default to spawnImportedMeshEntity")
    }

    // MARK: - find_entities spatial proximity filter

    func testFindEntitiesNearPositionReturnsCloseEntities() async {
        var wv = WorldView()
        // Entity at [0, 0, 0]
        let s1 = SceneSemanticSnapshot.Entity(
            id: "scene:10", name: "Near", kind: "Static Mesh", parentRef: nil, childRefs: [],
            isSelected: false, position: [0, 0, 0], scale: nil, eulerDegrees: nil,
            worldPosition: [0, 0, 0], worldEulerDegrees: nil, worldScale: nil, components: []
        )
        // Entity at [100, 0, 0]
        let s2 = SceneSemanticSnapshot.Entity(
            id: "scene:11", name: "Far", kind: "Static Mesh", parentRef: nil, childRefs: [],
            isSelected: false, position: [100, 0, 0], scale: nil, eulerDegrees: nil,
            worldPosition: [100, 0, 0], worldEulerDegrees: nil, worldScale: nil, components: []
        )
        wv.apply(snapshot: SceneSemanticSnapshot(
            sceneRevision: 1, entityCount: 2, entities: [s1, s2],
            selectedRef: nil, workspaceMode: nil, localeIdentifier: nil
        ))
        let session = Session(id: "near-filter", config: makeTestConfig(), initialWorldView: wv)

        let json = await session.findEntitiesResult(input: [
            "near_position": [0.0, 0.0, 0.0],
            "near_radius": 5.0,
        ])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let entities = result["entities"] as! [[String: Any]]

        XCTAssertEqual(entities.count, 1, "only the nearby entity should be returned")
        XCTAssertEqual(entities.first?["name"] as? String, "Near")
    }

    func testFindEntitiesNearPositionExcludesEntitiesOutsideRadius() async {
        var wv = WorldView()
        let s1 = SceneSemanticSnapshot.Entity(
            id: "scene:20", name: "E1", kind: "Static Mesh", parentRef: nil, childRefs: [],
            isSelected: false, position: [3, 0, 0], scale: nil, eulerDegrees: nil,
            worldPosition: [3, 0, 0], worldEulerDegrees: nil, worldScale: nil, components: []
        )
        let s2 = SceneSemanticSnapshot.Entity(
            id: "scene:21", name: "E2", kind: "Static Mesh", parentRef: nil, childRefs: [],
            isSelected: false, position: [6, 0, 0], scale: nil, eulerDegrees: nil,
            worldPosition: [6, 0, 0], worldEulerDegrees: nil, worldScale: nil, components: []
        )
        wv.apply(snapshot: SceneSemanticSnapshot(
            sceneRevision: 1, entityCount: 2, entities: [s1, s2],
            selectedRef: nil, workspaceMode: nil, localeIdentifier: nil
        ))
        let session = Session(id: "radius-exclude", config: makeTestConfig(), initialWorldView: wv)

        let json = await session.findEntitiesResult(input: [
            "near_position": [0.0, 0.0, 0.0],
            "near_radius": 4.0,
        ])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let entities = result["entities"] as! [[String: Any]]

        XCTAssertEqual(entities.count, 1)
        XCTAssertEqual(entities.first?["name"] as? String, "E1",
                       "entity at distance 3 is within radius 4; entity at distance 6 must be excluded")
    }

    func testFindEntitiesNearPositionFallsBackToLocalPosition() async {
        var wv = WorldView()
        // Entity with local position only (root entity, no worldPosition in evaluated)
        wv.apply(event: .entityAdded(ref: "scene:30", name: "RootEntity", kind: "Static Mesh"))
        wv.apply(event: .entityAuthoredChanged(ref: "scene:30", property: "position",
                                               value: .vec3(2, 0, 0)))
        let session = Session(id: "local-pos-fallback", config: makeTestConfig(), initialWorldView: wv)

        let json = await session.findEntitiesResult(input: [
            "near_position": [0.0, 0.0, 0.0],
            "near_radius": 5.0,
        ])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let entities = result["entities"] as! [[String: Any]]

        XCTAssertEqual(entities.count, 1,
                       "entity with only local position at [2,0,0] should match radius 5 query at origin")
    }

    func testFindEntitiesNearPositionRequiresBothParams() async {
        var wv = WorldView()
        let s = SceneSemanticSnapshot.Entity(
            id: "scene:40", name: "Any", kind: "Static Mesh", parentRef: nil, childRefs: [],
            isSelected: false, position: [0, 0, 0], scale: nil, eulerDegrees: nil,
            worldPosition: [0, 0, 0], worldEulerDegrees: nil, worldScale: nil, components: []
        )
        wv.apply(snapshot: SceneSemanticSnapshot(
            sceneRevision: 1, entityCount: 1, entities: [s],
            selectedRef: nil, workspaceMode: nil, localeIdentifier: nil
        ))
        let session = Session(id: "no-radius", config: makeTestConfig(), initialWorldView: wv)

        // near_position without near_radius — should return all entities (filter not applied)
        let json = await session.findEntitiesResult(input: ["near_position": [0.0, 0.0, 0.0]])
        let result = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let entities = result["entities"] as! [[String: Any]]

        XCTAssertEqual(entities.count, 1, "without near_radius the spatial filter should not be applied")
    }

    func testSpawnKindDirectionalLightCreatesCorrectLightType() throws {
        let scene = SceneRuntime()
        let json = """
        {"summary":"sun","steps":[{"op":"spawn_entity","label":"Sun","spawn_kind":"light","light_type":"directional"}]}
        """
        let plan = try JSONDecoder().decode(SceneEditPlan.self, from: Data(json.utf8))
        let transaction = try SceneEditPlanExecutor().buildTransaction(from: plan, scene: scene)
        let ops = transaction.operations.compactMap { if case let .scene(m) = $0 { return m } else { return nil } }
        let hasDirectional = ops.contains {
            if case let .spawnLightEntity(_, lt, _) = $0 { return lt == .directional }
            return false
        }
        XCTAssertTrue(hasDirectional, "spawn_kind 'light' with light_type 'directional' must produce directional light")
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
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
