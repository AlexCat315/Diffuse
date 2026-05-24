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

// MARK: - PerceptionRequest tests

extension PerceptionRuntimeTests {
    func testPerceptionRequestDefaultsAreReasonable() {
        let req = PerceptionRequest(inputURI: "file:///tmp/test.jpg")
        XCTAssertFalse(req.requestID.isEmpty)
        XCTAssertEqual(req.task, .classification)
        XCTAssertEqual(req.maxResults, 5)
        XCTAssertEqual(req.confidenceThreshold, 0.5, accuracy: 0.001)
    }

    func testPerceptionRequestRoundTripsCodable() throws {
        let req = PerceptionRequest(requestID: "r1",
                                    task: .objectDetection,
                                    inputURI: "file:///tmp/img.png",
                                    maxResults: 10,
                                    confidenceThreshold: 0.7,
                                    hints: ["category_hint": "furniture"])
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PerceptionRequest.self, from: data)
        XCTAssertEqual(decoded, req)
    }
}

// MARK: - EvaluationGate tests

extension PerceptionRuntimeTests {
    func testEvaluationGateApprovesGoodDetector() {
        let metrics = ModelMetricsRecord(
            modelID: "rt_detr_v2",
            task: .objectDetection,
            dataset: "coco_val2017",
            evaluatorVersion: "eval_v1",
            mapAt50: 0.55,
            meanLatencyMs: 45,
            p95LatencyMs: 120
        )
        XCTAssertEqual(EvaluationGate.default.evaluate(metrics), .approved)
    }

    func testEvaluationGateRejectsLowMapDetector() {
        let metrics = ModelMetricsRecord(
            modelID: "weak_detector",
            task: .objectDetection,
            dataset: "coco_val2017",
            evaluatorVersion: "eval_v1",
            mapAt50: 0.25,
            meanLatencyMs: 30,
            p95LatencyMs: 80
        )
        if case let .rejectedAccuracy(actual, required) = EvaluationGate.default.evaluate(metrics) {
            XCTAssertEqual(actual, 0.25, accuracy: 0.001)
            XCTAssertEqual(required, 0.40, accuracy: 0.001)
        } else {
            XCTFail("Expected rejectedAccuracy")
        }
    }

    func testEvaluationGateRejectsSlowModel() {
        let metrics = ModelMetricsRecord(
            modelID: "slow_classifier",
            task: .classification,
            dataset: "imagenet",
            evaluatorVersion: "eval_v1",
            topKAccuracy: 0.85,
            meanLatencyMs: 800,
            p95LatencyMs: 2500
        )
        if case let .rejectedLatency(p95, max) = EvaluationGate.default.evaluate(metrics) {
            XCTAssertEqual(p95, 2500, accuracy: 1)
            XCTAssertEqual(max, 1000, accuracy: 1)
        } else {
            XCTFail("Expected rejectedLatency")
        }
    }

    func testEvaluationGateReturnsNotEvaluatedWithMissingMetrics() {
        let metrics = ModelMetricsRecord(
            modelID: "no_metrics_detector",
            task: .objectDetection,
            dataset: "unknown",
            evaluatorVersion: "eval_v1",
            mapAt50: nil,
            meanLatencyMs: 50,
            p95LatencyMs: 100
        )
        XCTAssertEqual(EvaluationGate.default.evaluate(metrics), .notEvaluated)
    }

    func testEvaluationGateDecisionDescription() {
        XCTAssertEqual(EvaluationGateDecision.approved.description, "approved")
        XCTAssertEqual(EvaluationGateDecision.notEvaluated.description,
                       "not evaluated — no metrics record available")
    }

    func testPerceptionRequestHandleThrowsForMissingFile() {
        let worker = MockPerceptionWorker(result: makeClassificationResult(label: "x", confidence: 1.0))
        let req = PerceptionRequest(inputURI: "/nonexistent/path/image.jpg")
        XCTAssertThrowsError(try worker.handle(request: req))
    }
}

// MARK: - LocalArtifactStore tests

extension PerceptionRuntimeTests {
    func testArtifactStoreWritesAndResolvesBlob() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava_artifact_test_\(UUID().uuidString)")
        let store = try LocalArtifactStore(baseURL: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data("hello perception".utf8)
        let ref = try await store.write(payload,
                                        mediaType: "application/octet-stream",
                                        semanticKind: "test_blob")

        XCTAssertTrue(ref.uri.hasPrefix("artifacts://"))
        XCTAssertFalse(ref.contentHash?.isEmpty ?? true)
        XCTAssertEqual(ref.redaction, "prompt_forbidden")
        let resolved = await store.resolve(ref)
        XCTAssertNotNil(resolved)
        let readBack = try await store.read(ref)
        XCTAssertEqual(readBack, payload)
    }

    func testArtifactStoreIsIdempotentForSameContent() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava_artifact_idem_\(UUID().uuidString)")
        let store = try LocalArtifactStore(baseURL: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = Data("stable content".utf8)
        let ref1 = try await store.write(payload, mediaType: "application/octet-stream", semanticKind: "x")
        let ref2 = try await store.write(payload, mediaType: "application/octet-stream", semanticKind: "x")

        XCTAssertEqual(ref1.contentHash, ref2.contentHash)
        XCTAssertEqual(ref1.uri, ref2.uri)
    }
}

// MARK: - ManifestScanner + PerceptionSchemaValidator tests

extension PerceptionRuntimeTests {
    func testSchemaValidatorPassesValidManifest() throws {
        let manifest = validManifest()
        XCTAssertNoThrow(try PerceptionSchemaValidator.validate(manifest))
    }

    func testSchemaValidatorRejectsUnknownVersion() {
        var manifest = validManifest()
        manifest = PerceptionModelManifest(
            schemaVersion: "guava.perception.model_manifest.v99",
            modelID: manifest.modelID,
            displayName: manifest.displayName,
            task: manifest.task,
            backendFamily: manifest.backendFamily,
            runtime: manifest.runtime,
            inputContract: manifest.inputContract,
            outputContract: manifest.outputContract,
            license: manifest.license
        )
        XCTAssertThrowsError(try PerceptionSchemaValidator.validate(manifest)) { error in
            if case let PerceptionSchemaValidator.ValidationError.unsupportedSchemaVersion(v) = error {
                XCTAssertTrue(v.contains("v99"))
            } else {
                XCTFail("Expected unsupportedSchemaVersion, got \(error)")
            }
        }
    }

    func testManifestScannerPicksUpManifestJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava_manifest_scan_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let manifest = validManifest()
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: dir.appendingPathComponent("manifest.json"))

        let result = ManifestScanner.scan(directory: dir)
        XCTAssertEqual(result.manifests.count, 1)
        XCTAssertEqual(result.manifests[0].modelID, "test_classifier_v1")
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testManifestScannerCollectsErrorsForInvalidJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava_manifest_err_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "not valid json".data(using: .utf8)!
            .write(to: dir.appendingPathComponent("manifest.json"))

        let result = ManifestScanner.scan(directory: dir)
        XCTAssertTrue(result.manifests.isEmpty)
        XCTAssertEqual(result.errors.count, 1)
    }

    private func validManifest() -> PerceptionModelManifest {
        PerceptionModelManifest(
            modelID: "test_classifier_v1",
            displayName: "Test Classifier",
            task: .classification,
            backendFamily: "test",
            runtime: PerceptionRuntimeConfig(preferredRuntime: "none"),
            inputContract: "guava.perception.input.rgb_image.v1",
            outputContract: "guava.perception.output.classifications.v1",
            license: PerceptionLicenseMetadata(
                codeLicense: "MIT",
                weightsLicense: "MIT",
                commercialUse: "allowed",
                redistribution: "allowed")
        )
    }
}

// MARK: - PerceptionWorkerFactory tests

extension PerceptionRuntimeTests {
    func testWorkerFactoryBuildsWorkerForRegisteredBackend() {
        var factory = PerceptionWorkerFactory()
        let lampResult = makeClassificationResult(label: "lamp", confidence: 0.9)
        factory.register(backendFamily: "test") { _ in
            MockPerceptionWorker(result: lampResult)
        }
        let manifest = PerceptionModelManifest(
            modelID: "lamp_detector",
            displayName: "Lamp Detector",
            task: .classification,
            backendFamily: "test",
            runtime: PerceptionRuntimeConfig(preferredRuntime: "none"),
            inputContract: "guava.perception.input.rgb_image.v1",
            outputContract: "guava.perception.output.classifications.v1",
            license: PerceptionLicenseMetadata(codeLicense: "MIT", weightsLicense: "MIT",
                                               commercialUse: "allowed",
                                               redistribution: "allowed")
        )
        XCTAssertNotNil(factory.makeWorker(for: manifest))
    }

    func testWorkerFactoryReturnsNilForUnregisteredBackend() {
        let factory = PerceptionWorkerFactory()
        let manifest = PerceptionModelManifest(
            modelID: "unknown",
            displayName: "Unknown",
            task: .classification,
            backendFamily: "onnxruntime",
            runtime: PerceptionRuntimeConfig(preferredRuntime: "onnxruntime"),
            inputContract: "guava.perception.input.rgb_image.v1",
            outputContract: "guava.perception.output.classifications.v1",
            license: PerceptionLicenseMetadata(codeLicense: "MIT", weightsLicense: "MIT",
                                               commercialUse: "allowed",
                                               redistribution: "allowed")
        )
        XCTAssertNil(factory.makeWorker(for: manifest))
    }
}
