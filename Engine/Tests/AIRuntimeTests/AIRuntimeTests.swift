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
