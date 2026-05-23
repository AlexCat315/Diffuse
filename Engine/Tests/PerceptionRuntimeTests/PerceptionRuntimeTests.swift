import IntentRuntime
import PerceptionRuntime
import XCTest

final class PerceptionRuntimeTests: XCTestCase {
    func testLicenseGateRejectsNonCommercialWeights() {
        let manifest = PerceptionModelManifest(
            modelID: "nc_detector",
            displayName: "NC Detector",
            task: .objectDetection,
            backendFamily: "test",
            runtime: PerceptionRuntimeConfig(preferredRuntime: "onnxruntime"),
            inputContract: "guava.perception.input.rgb_image.v1",
            outputContract: "guava.perception.output.detections.v1",
            license: PerceptionLicenseMetadata(
                codeLicense: "Apache-2.0",
                weightsLicense: "CC-BY-NC-4.0",
                datasetLineage: ["fixture"],
                commercialUse: "non-commercial",
                redistribution: "restricted",
                nonCommercialOnly: true)
        )

        XCTAssertEqual(
            LicenseGate().evaluate(manifest, distributionMode: .commercialBinary),
            .disabledNonCommercial
        )
    }

    func testPerceptionResultRoundTripsThroughCodable() throws {
        let result = makeClassificationResult(label: "chair", confidence: 0.91)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(PerceptionResult.self, from: data)

        XCTAssertEqual(decoded, result)
    }

    func testClassificationResultMapsToInferredWorldEvents() {
        let result = makeClassificationResult(label: "chair", confidence: 0.91)
        let events = PerceptionWorldEventMapper().makeWorldEvents(from: result, targetRef: "scene:1")

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first, .entityInferredUpdated(ref: "scene:1",
                                                            property: "object_category",
                                                            value: .string("chair"),
                                                            confidence: 0.91,
                                                            source: "perception:fixture_classifier"))
    }

    func testAppleVisionWorkerRunsAgainstFixtureImage() throws {
        #if canImport(Vision)
        let testFile = URL(fileURLWithPath: #filePath)
        let engineRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let imageURL = engineRoot.appendingPathComponent("third-party/sdl3/test/trashcan.png")

        let result = try AppleVisionPerceptionWorker()
            .analyzeImage(at: imageURL, requestID: "vision_smoke", maxResults: 3)

        XCTAssertEqual(result.modelID, "apple_vision_classify_image_v1")
        XCTAssertFalse(result.observations.isEmpty)
        #else
        throw XCTSkip("Apple Vision is unavailable on this platform")
        #endif
    }

    private func makeClassificationResult(label: String, confidence: Double) -> PerceptionResult {
        PerceptionResult(
            requestID: "request_1",
            modelID: "fixture_classifier",
            modelVersion: "test",
            task: .classification,
            status: "success",
            observations: [
                .classification(ClassificationObservation(
                    id: "classification_0",
                    label: label,
                    labelSpace: "fixture",
                    confidence: confidence,
                    semanticCandidates: [
                        PerceptionSemanticCandidate(kind: "object_category",
                                                    label: label,
                                                    confidence: confidence),
                    ],
                    evidence: [
                        PerceptionEvidence(kind: "fixture",
                                           source: "fixture_classifier",
                                           confidence: confidence),
                    ]
                )),
            ],
            timing: PerceptionTimingInfo(totalMilliseconds: 1),
            provenance: PerceptionProvenance(source: "fixture", modelID: "fixture_classifier")
        )
    }
}
