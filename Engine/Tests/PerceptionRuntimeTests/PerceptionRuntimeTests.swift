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

    func testObjectDetectionResultMapsToInferredWorldEvents() {
        let result = makeObjectDetectionResult(label: "table", confidence: 0.87,
                                               bbox: BBox2D(x: 10, y: 20, width: 200, height: 150))
        let events = PerceptionWorldEventMapper().makeWorldEvents(from: result, targetRef: "scene:5")

        let bboxEvent = events.first { event in
            if case .entityInferredUpdated(_, "perception.bbox2d", _, _, _) = event { return true }
            return false
        }
        let categoryEvent = events.first { event in
            if case .entityInferredUpdated(_, "object_category", .string("table"), _, _) = event { return true }
            return false
        }
        XCTAssertNotNil(categoryEvent)
        XCTAssertNotNil(bboxEvent)
    }

    func testImageEmbeddingResultWritesEmbeddingAvailableFlag() {
        let result = makeImageEmbeddingResult(vectorSpaceID: "openclip_vit_b32")
        let events = PerceptionWorldEventMapper().makeWorldEvents(from: result, targetRef: "scene:7")

        let embeddingEvent = events.first { event in
            if case .entityInferredUpdated(_, "perception.embedding_available",
                                           .string("openclip_vit_b32"), _, _) = event { return true }
            return false
        }
        XCTAssertNotNil(embeddingEvent)
    }

    func testObjectDetectionObservationRoundTripsCodable() throws {
        let obs = PerceptionObservation.objectDetection(DetectedObjectObservation(
            id: "det_0",
            label: "chair",
            labelSpace: "coco_80",
            confidence: 0.92,
            bbox2D: BBox2D(x: 5, y: 10, width: 100, height: 120),
            semanticCandidates: [PerceptionSemanticCandidate(kind: "object_category",
                                                              label: "chair",
                                                              confidence: 0.92)],
            evidence: []
        ))
        let data = try JSONEncoder().encode(obs)
        let decoded = try JSONDecoder().decode(PerceptionObservation.self, from: data)
        XCTAssertEqual(decoded, obs)
    }

    func testImageEmbeddingObservationRoundTripsCodable() throws {
        let ref = ArtifactRef(uri: "artifacts://embed/0",
                              contentHash: "abc123",
                              mediaType: "application/octet-stream",
                              semanticKind: "embedding",
                              redaction: "prompt_forbidden")
        let obs = PerceptionObservation.imageEmbedding(ImageEmbeddingObservation(
            id: "emb_0",
            embeddingRef: ref,
            modelID: "openclip_vit_b32",
            vectorSpaceID: "openclip_vit_b32"
        ))
        let data = try JSONEncoder().encode(obs)
        let decoded = try JSONDecoder().decode(PerceptionObservation.self, from: data)
        XCTAssertEqual(decoded, obs)
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

    func testPerceptionServiceTagsEntityWithMatchingWorker() async throws {
        let worker = MockPerceptionWorker(result: makeClassificationResult(label: "chair", confidence: 0.91))
        let service = PerceptionService()
        await service.register(worker)

        let events = try await service.tag(entityRef: "scene:1",
                                           imageURL: URL(fileURLWithPath: "/dev/null"),
                                           task: .classification)

        XCTAssertFalse(events.isEmpty)
        XCTAssertEqual(events.first, .entityInferredUpdated(ref: "scene:1",
                                                             property: "object_category",
                                                             value: .string("chair"),
                                                             confidence: 0.91,
                                                             source: "perception:fixture_classifier"))
    }

    func testPerceptionServiceThrowsWhenNoWorkerForTask() async throws {
        let service = PerceptionService()

        do {
            _ = try await service.tag(entityRef: "scene:1",
                                      imageURL: URL(fileURLWithPath: "/dev/null"),
                                      task: .objectDetection)
            XCTFail("Expected workerUnavailable error")
        } catch let PerceptionRuntimeError.workerUnavailable(reason) {
            XCTAssertTrue(reason.contains("object_detection"))
        }
    }

    func testPerceptionServiceSkipsLicenseDeniedWorker() async throws {
        let ncWorker = NonCommercialMockWorker()
        let service = PerceptionService(distributionMode: .commercialBinary)
        await service.register(ncWorker)

        let worker = await service.availableWorker(for: .classification)
        XCTAssertNil(worker)
    }

    func testAnalyzeImageAsyncCallsThroughToSync() async throws {
        let worker = MockPerceptionWorker(result: makeClassificationResult(label: "lamp", confidence: 0.77))
        let url = URL(fileURLWithPath: "/dev/null")

        let result = try await worker.analyzeImageAsync(at: url, requestID: "async_test", maxResults: 2)

        XCTAssertEqual(worker.callCount, 1)
        XCTAssertEqual(worker.lastRequestID, "async_test")
        XCTAssertEqual(worker.lastMaxResults, 2)
        XCTAssertEqual(result, worker.result)
    }

    func testAnalyzeImageAsyncDefaultParametersForwardCorrectly() async throws {
        let worker = MockPerceptionWorker(result: makeClassificationResult(label: "table", confidence: 0.88))
        let url = URL(fileURLWithPath: "/dev/null")

        _ = try await worker.analyzeImageAsync(at: url)

        XCTAssertEqual(worker.lastMaxResults, 5)
        XCTAssertFalse(worker.lastRequestID.isEmpty)
    }

    private func makeObjectDetectionResult(label: String,
                                            confidence: Double,
                                            bbox: BBox2D? = nil) -> PerceptionResult {
        PerceptionResult(
            requestID: "request_det",
            modelID: "fixture_detector",
            modelVersion: "test",
            task: .objectDetection,
            status: "success",
            observations: [
                .objectDetection(DetectedObjectObservation(
                    id: "det_0",
                    label: label,
                    labelSpace: "fixture",
                    confidence: confidence,
                    bbox2D: bbox,
                    semanticCandidates: [
                        PerceptionSemanticCandidate(kind: "object_category",
                                                    label: label,
                                                    confidence: confidence),
                    ],
                    evidence: []
                )),
            ],
            timing: PerceptionTimingInfo(totalMilliseconds: 2),
            provenance: PerceptionProvenance(source: "fixture", modelID: "fixture_detector")
        )
    }

    private func makeImageEmbeddingResult(vectorSpaceID: String) -> PerceptionResult {
        let ref = ArtifactRef(uri: "artifacts://embed/0",
                              mediaType: "application/octet-stream",
                              semanticKind: "embedding",
                              redaction: "prompt_forbidden")
        return PerceptionResult(
            requestID: "request_emb",
            modelID: "fixture_embedder",
            modelVersion: "test",
            task: .imageEmbedding,
            status: "success",
            observations: [
                .imageEmbedding(ImageEmbeddingObservation(
                    id: "emb_0",
                    embeddingRef: ref,
                    modelID: "fixture_embedder",
                    vectorSpaceID: vectorSpaceID
                )),
            ],
            timing: PerceptionTimingInfo(totalMilliseconds: 5),
            provenance: PerceptionProvenance(source: "fixture", modelID: "fixture_embedder")
        )
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

private final class MockPerceptionWorker: PerceptionWorker, @unchecked Sendable {
    let result: PerceptionResult
    var callCount = 0
    var lastRequestID = ""
    var lastMaxResults = 0

    init(result: PerceptionResult) { self.result = result }

    var manifest: PerceptionModelManifest {
        PerceptionModelManifest(
            modelID: "mock",
            displayName: "Mock",
            task: .classification,
            backendFamily: "test",
            runtime: PerceptionRuntimeConfig(preferredRuntime: "none"),
            inputContract: "",
            outputContract: "",
            license: PerceptionLicenseMetadata(
                codeLicense: "MIT",
                weightsLicense: "MIT",
                commercialUse: "allowed",
                redistribution: "allowed")
        )
    }

    func analyzeImage(at url: URL, requestID: String, maxResults: Int) throws -> PerceptionResult {
        callCount += 1
        lastRequestID = requestID
        lastMaxResults = maxResults
        return result
    }
}

private struct NonCommercialMockWorker: PerceptionWorker {
    var manifest: PerceptionModelManifest {
        PerceptionModelManifest(
            modelID: "nc_classifier",
            displayName: "NC Classifier",
            task: .classification,
            backendFamily: "test",
            runtime: PerceptionRuntimeConfig(preferredRuntime: "none"),
            inputContract: "",
            outputContract: "",
            license: PerceptionLicenseMetadata(
                codeLicense: "MIT",
                weightsLicense: "CC-BY-NC-4.0",
                commercialUse: "non-commercial",
                redistribution: "restricted",
                nonCommercialOnly: true)
        )
    }

    func analyzeImage(at url: URL, requestID: String, maxResults: Int) throws -> PerceptionResult {
        fatalError("should not be called — license gate must block this worker")
    }
}
