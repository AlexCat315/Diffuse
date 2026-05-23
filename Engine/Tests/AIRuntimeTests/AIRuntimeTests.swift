import AIRuntime
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
