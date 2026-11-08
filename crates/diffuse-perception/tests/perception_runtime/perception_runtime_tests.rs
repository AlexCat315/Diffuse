//! `PerceptionRuntimeTests.swift` — translation, 1:1 test count.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Arc, Mutex};

use diffuse_intent::transactions::world_event::{WorldEvent, WorldPropertyValue};
use diffuse_perception::{
    AppleVisionPerceptionWorker, ArtifactRef, BBox2D, ClassificationObservation,
    DetectedObjectObservation, EvaluationGate, EvaluationGateDecision, ImageEmbeddingObservation,
    LicenseGate, LocalArtifactStore, ManifestScanner, ModelMetricsRecord,
    PerceptionDistributionMode, PerceptionEvidence, PerceptionLicenseMetadata,
    PerceptionModelManifest, PerceptionObservation, PerceptionProvenance, PerceptionRequest,
    PerceptionResult, PerceptionRuntimeConfig, PerceptionRuntimeError, PerceptionSchemaValidator,
    PerceptionSemanticCandidate, PerceptionService, PerceptionTask, PerceptionTimingInfo,
    PerceptionWorker, PerceptionWorkerFactory, PerceptionWorldEventMapper, SwiftDate,
    ValidationError,
};

// MARK: - Fixtures

fn make_classification_result(label: &str, confidence: f64) -> PerceptionResult {
    PerceptionResult::new(
        "request_1",
        "fixture_classifier",
        "test",
        PerceptionTask::Classification,
        "success",
        vec![PerceptionObservation::Classification(
            ClassificationObservation::new(
                "classification_0",
                label,
                "fixture",
                confidence,
                vec![PerceptionSemanticCandidate::new(
                    "object_category",
                    label,
                    confidence,
                )],
                vec![PerceptionEvidence::new(
                    "fixture",
                    "fixture_classifier",
                    confidence,
                    None,
                )],
            ),
        )],
        PerceptionTimingInfo::new(1.0),
        PerceptionProvenance::new("fixture", "fixture_classifier"),
    )
}

fn make_object_detection_result(
    label: &str,
    confidence: f64,
    bbox: Option<BBox2D>,
) -> PerceptionResult {
    PerceptionResult::new(
        "request_det",
        "fixture_detector",
        "test",
        PerceptionTask::ObjectDetection,
        "success",
        vec![PerceptionObservation::ObjectDetection(
            DetectedObjectObservation::new(
                "det_0",
                label,
                "fixture",
                confidence,
                bbox,
                vec![PerceptionSemanticCandidate::new(
                    "object_category",
                    label,
                    confidence,
                )],
                Vec::new(),
            ),
        )],
        PerceptionTimingInfo::new(2.0),
        PerceptionProvenance::new("fixture", "fixture_detector"),
    )
}

fn make_image_embedding_result(vector_space_id: &str) -> PerceptionResult {
    let artifact_ref = ArtifactRef::new(
        "artifacts://embed/0",
        None,
        "application/octet-stream",
        "embedding",
    );
    PerceptionResult::new(
        "request_emb",
        "fixture_embedder",
        "test",
        PerceptionTask::ImageEmbedding,
        "success",
        vec![PerceptionObservation::ImageEmbedding(
            ImageEmbeddingObservation::new(
                "emb_0",
                artifact_ref,
                "fixture_embedder",
                vector_space_id,
            ),
        )],
        PerceptionTimingInfo::new(5.0),
        PerceptionProvenance::new("fixture", "fixture_embedder"),
    )
}

fn valid_manifest() -> PerceptionModelManifest {
    PerceptionModelManifest::new(
        "test_classifier_v1",
        "Test Classifier",
        PerceptionTask::Classification,
        "test",
        PerceptionRuntimeConfig::new("none"),
        "cove.perception.input.rgb_image.v1",
        "cove.perception.output.classifications.v1",
        PerceptionLicenseMetadata::with_defaults("MIT", "MIT", Vec::new(), "allowed", "allowed"),
    )
}

fn manifest_with_backend(backend_family: &str) -> PerceptionModelManifest {
    PerceptionModelManifest::new(
        "lamp_detector",
        "Lamp Detector",
        PerceptionTask::Classification,
        backend_family,
        PerceptionRuntimeConfig::new("none"),
        "cove.perception.input.rgb_image.v1",
        "cove.perception.output.classifications.v1",
        PerceptionLicenseMetadata::with_defaults("MIT", "MIT", Vec::new(), "allowed", "allowed"),
    )
}

fn inferred_event<'a>(events: &'a [WorldEvent], property: &str) -> Option<&'a WorldEvent> {
    events.iter().find(|event| {
        matches!(
            event,
            WorldEvent::EntityInferredUpdated { property: name, .. } if name == property
        )
    })
}

// MARK: - Workers

struct MockPerceptionWorker {
    result: PerceptionResult,
    call_count: Mutex<i64>,
    last_request_id: Mutex<String>,
    last_max_results: Mutex<i64>,
}

impl MockPerceptionWorker {
    fn new(result: PerceptionResult) -> Self {
        MockPerceptionWorker {
            result,
            call_count: Mutex::new(0),
            last_request_id: Mutex::new(String::new()),
            last_max_results: Mutex::new(0),
        }
    }

    fn call_count(&self) -> i64 {
        *self
            .call_count
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn last_request_id(&self) -> String {
        self.last_request_id
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    fn last_max_results(&self) -> i64 {
        *self
            .last_max_results
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl PerceptionWorker for MockPerceptionWorker {
    fn manifest(&self) -> PerceptionModelManifest {
        PerceptionModelManifest::new(
            "mock",
            "Mock",
            PerceptionTask::Classification,
            "test",
            PerceptionRuntimeConfig::new("none"),
            "",
            "",
            PerceptionLicenseMetadata::with_defaults(
                "MIT",
                "MIT",
                Vec::new(),
                "allowed",
                "allowed",
            ),
        )
    }

    fn analyze_image(
        &self,
        _url: &Path,
        request_id: &str,
        max_results: i64,
    ) -> Result<PerceptionResult, PerceptionRuntimeError> {
        *self
            .call_count
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) += 1;
        *self
            .last_request_id
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = request_id.to_string();
        *self
            .last_max_results
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = max_results;
        Ok(self.result.clone())
    }
}

struct NonCommercialMockWorker;

impl PerceptionWorker for NonCommercialMockWorker {
    fn manifest(&self) -> PerceptionModelManifest {
        PerceptionModelManifest::new(
            "nc_classifier",
            "NC Classifier",
            PerceptionTask::Classification,
            "test",
            PerceptionRuntimeConfig::new("none"),
            "",
            "",
            PerceptionLicenseMetadata::new(
                "MIT",
                "CC-BY-NC-4.0",
                Vec::new(),
                "non-commercial",
                "restricted",
                false,
                false,
                true,
            ),
        )
    }

    fn analyze_image(
        &self,
        _url: &Path,
        _request_id: &str,
        _max_results: i64,
    ) -> Result<PerceptionResult, PerceptionRuntimeError> {
        panic!("should not be called — license gate must block this worker")
    }
}

// MARK: - License gate + contracts

#[test]
fn test_license_gate_rejects_non_commercial_weights() {
    let manifest = PerceptionModelManifest::new(
        "nc_detector",
        "NC Detector",
        PerceptionTask::ObjectDetection,
        "test",
        PerceptionRuntimeConfig::new("onnxruntime"),
        "cove.perception.input.rgb_image.v1",
        "cove.perception.output.detections.v1",
        PerceptionLicenseMetadata::new(
            "Apache-2.0",
            "CC-BY-NC-4.0",
            vec!["fixture".to_string()],
            "non-commercial",
            "restricted",
            false,
            false,
            true,
        ),
    );

    assert_eq!(
        LicenseGate::default().evaluate(&manifest, PerceptionDistributionMode::CommercialBinary),
        diffuse_perception::LicenseGateDecision::DisabledNonCommercial
    );
}

#[test]
fn test_perception_result_round_trips_through_codable() {
    let result = make_classification_result("chair", 0.91);

    let data = serde_json::to_vec(&result).expect("encode result");
    let decoded: PerceptionResult = serde_json::from_slice(&data).expect("decode result");

    assert_eq!(decoded, result);
}

#[test]
fn test_classification_result_maps_to_inferred_world_events() {
    let result = make_classification_result("chair", 0.91);
    let events = PerceptionWorldEventMapper::new().make_world_events(&result, "scene:1");

    assert_eq!(events.len(), 2);
    assert_eq!(
        events[0],
        WorldEvent::EntityInferredUpdated {
            ref_: "scene:1".to_string(),
            property: "object_category".to_string(),
            value: WorldPropertyValue::String("chair".to_string()),
            confidence: 0.91,
            source: Some("perception:fixture_classifier".to_string()),
        }
    );
}

#[test]
fn test_object_detection_result_maps_to_inferred_world_events() {
    let result =
        make_object_detection_result("table", 0.87, Some(BBox2D::new(10.0, 20.0, 200.0, 150.0)));
    let events = PerceptionWorldEventMapper::new().make_world_events(&result, "scene:5");

    let bbox_event = inferred_event(&events, "perception.bbox2d");
    let category_event = inferred_event(&events, "object_category");
    assert!(matches!(
        category_event,
        Some(WorldEvent::EntityInferredUpdated {
            value: WorldPropertyValue::String(label),
            ..
        }) if label == "table"
    ));
    assert!(bbox_event.is_some());
}

#[test]
fn test_image_embedding_result_writes_embedding_available_flag() {
    let result = make_image_embedding_result("openclip_vit_b32");
    let events = PerceptionWorldEventMapper::new().make_world_events(&result, "scene:7");

    let embedding_event = inferred_event(&events, "perception.embedding_available");
    assert!(matches!(
        embedding_event,
        Some(WorldEvent::EntityInferredUpdated {
            value: WorldPropertyValue::String(vector_space),
            ..
        }) if vector_space == "openclip_vit_b32"
    ));
}

#[test]
fn test_object_detection_observation_round_trips_codable() {
    let observation = PerceptionObservation::ObjectDetection(DetectedObjectObservation::new(
        "det_0",
        "chair",
        "coco_80",
        0.92,
        Some(BBox2D::new(5.0, 10.0, 100.0, 120.0)),
        vec![PerceptionSemanticCandidate::new(
            "object_category",
            "chair",
            0.92,
        )],
        Vec::new(),
    ));
    let data = serde_json::to_vec(&observation).expect("encode observation");
    let decoded: PerceptionObservation = serde_json::from_slice(&data).expect("decode observation");
    assert_eq!(decoded, observation);
}

#[test]
fn test_image_embedding_observation_round_trips_codable() {
    let artifact_ref = ArtifactRef::with_options(
        "artifacts://embed/0",
        Some("abc123".to_string()),
        "application/octet-stream",
        "embedding",
        "prompt_forbidden",
    );
    let observation = PerceptionObservation::ImageEmbedding(ImageEmbeddingObservation::new(
        "emb_0",
        artifact_ref,
        "openclip_vit_b32",
        "openclip_vit_b32",
    ));
    let data = serde_json::to_vec(&observation).expect("encode observation");
    let decoded: PerceptionObservation = serde_json::from_slice(&data).expect("decode observation");
    assert_eq!(decoded, observation);
}

#[test]
fn test_apple_vision_worker_runs_against_fixture_image() {
    if std::env::var("COVE_RUN_VISION_SMOKE_TESTS").as_deref() != Ok("1") {
        return;
    }
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    {
        let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
        let workspace = manifest_dir
            .parent()
            .and_then(Path::parent)
            .expect("diffuse-perception lives under crates/");
        let image_url = workspace.join("Engine/third-party/sdl3/test/trashcan.png");

        let result = AppleVisionPerceptionWorker::new()
            .analyze_image(&image_url, "vision_smoke", 3)
            .expect("Vision smoke inference");

        assert_eq!(result.model_id, "apple_vision_classify_image_v1");
        assert!(!result.observations.is_empty());
    }
}

// MARK: - Service

#[test]
fn test_perception_service_tags_entity_with_matching_worker() {
    let worker = Arc::new(MockPerceptionWorker::new(make_classification_result(
        "chair", 0.91,
    )));
    let service = PerceptionService::new();
    service.register(worker);

    let events = service
        .tag_default("scene:1", Path::new("/dev/null"))
        .expect("tag entity");

    assert!(!events.is_empty());
    assert_eq!(
        events[0],
        WorldEvent::EntityInferredUpdated {
            ref_: "scene:1".to_string(),
            property: "object_category".to_string(),
            value: WorldPropertyValue::String("chair".to_string()),
            confidence: 0.91,
            source: Some("perception:fixture_classifier".to_string()),
        }
    );
}

#[test]
fn test_perception_service_throws_when_no_worker_for_task() {
    let service = PerceptionService::new();

    match service.tag(
        "scene:1",
        Path::new("/dev/null"),
        PerceptionTask::ObjectDetection,
        5,
    ) {
        Err(PerceptionRuntimeError::WorkerUnavailable(reason)) => {
            assert!(reason.contains("object_detection"));
        }
        other => panic!("expected workerUnavailable, got {other:?}"),
    }
}

#[test]
fn test_perception_service_skips_license_denied_worker() {
    let service = PerceptionService::with_options(
        LicenseGate::default(),
        PerceptionDistributionMode::CommercialBinary,
        PerceptionWorldEventMapper::new(),
    );
    service.register(Arc::new(NonCommercialMockWorker));

    let worker = service.available_worker(PerceptionTask::Classification);
    assert!(worker.is_none());
}

#[test]
fn test_analyze_image_async_calls_through_to_sync() {
    let worker = MockPerceptionWorker::new(make_classification_result("lamp", 0.77));
    let url = Path::new("/dev/null");

    let result = worker
        .analyze_image_async(url, "async_test", 2)
        .expect("async inference");

    assert_eq!(worker.call_count(), 1);
    assert_eq!(worker.last_request_id(), "async_test");
    assert_eq!(worker.last_max_results(), 2);
    assert_eq!(result, worker.result);
}

#[test]
fn test_analyze_image_async_default_parameters_forward_correctly() {
    let worker = MockPerceptionWorker::new(make_classification_result("table", 0.88));
    let url = Path::new("/dev/null");

    let _ = worker
        .analyze_image_async_default(url)
        .expect("async inference");

    assert_eq!(worker.last_max_results(), 5);
    assert!(!worker.last_request_id().is_empty());
}

// MARK: - PerceptionRequest

#[test]
fn test_perception_request_defaults_are_reasonable() {
    let request = PerceptionRequest::new("file:///tmp/test.jpg");
    assert!(!request.request_id.is_empty());
    assert_eq!(request.task, PerceptionTask::Classification);
    assert_eq!(request.max_results, 5);
    assert!((request.confidence_threshold - 0.5).abs() < 0.001);
}

#[test]
fn test_perception_request_round_trips_codable() {
    let mut hints = BTreeMap::new();
    hints.insert("category_hint".to_string(), "furniture".to_string());
    let request = PerceptionRequest::with_options(
        "r1".to_string(),
        PerceptionTask::ObjectDetection,
        "file:///tmp/img.png",
        10,
        0.7,
        None,
        hints,
    );
    let data = serde_json::to_vec(&request).expect("encode request");
    let decoded: PerceptionRequest = serde_json::from_slice(&data).expect("decode request");
    assert_eq!(decoded, request);
}

// MARK: - EvaluationGate

#[test]
fn test_evaluation_gate_approves_good_detector() {
    let metrics = ModelMetricsRecord::new(
        "rt_detr_v2",
        PerceptionTask::ObjectDetection,
        "coco_val2017",
        "eval_v1",
        SwiftDate::now(),
        Some(0.55),
        None,
        None,
        45.0,
        120.0,
    );
    assert_eq!(
        EvaluationGate::default().evaluate(&metrics),
        EvaluationGateDecision::Approved
    );
}

#[test]
fn test_evaluation_gate_rejects_low_map_detector() {
    let metrics = ModelMetricsRecord::new(
        "weak_detector",
        PerceptionTask::ObjectDetection,
        "coco_val2017",
        "eval_v1",
        SwiftDate::now(),
        Some(0.25),
        None,
        None,
        30.0,
        80.0,
    );
    match EvaluationGate::default().evaluate(&metrics) {
        EvaluationGateDecision::RejectedAccuracy { actual, required } => {
            assert!((actual - 0.25).abs() < 0.001);
            assert!((required - 0.40).abs() < 0.001);
        }
        other => panic!("expected rejectedAccuracy, got {other:?}"),
    }
}

#[test]
fn test_evaluation_gate_rejects_slow_model() {
    let metrics = ModelMetricsRecord::new(
        "slow_classifier",
        PerceptionTask::Classification,
        "imagenet",
        "eval_v1",
        SwiftDate::now(),
        None,
        Some(0.85),
        None,
        800.0,
        2500.0,
    );
    match EvaluationGate::default().evaluate(&metrics) {
        EvaluationGateDecision::RejectedLatency { p95_ms, max_ms } => {
            assert!((p95_ms - 2500.0).abs() < 1.0);
            assert!((max_ms - 1000.0).abs() < 1.0);
        }
        other => panic!("expected rejectedLatency, got {other:?}"),
    }
}

#[test]
fn test_evaluation_gate_returns_not_evaluated_with_missing_metrics() {
    let metrics = ModelMetricsRecord::new(
        "no_metrics_detector",
        PerceptionTask::ObjectDetection,
        "unknown",
        "eval_v1",
        SwiftDate::now(),
        None,
        None,
        None,
        50.0,
        100.0,
    );
    assert_eq!(
        EvaluationGate::default().evaluate(&metrics),
        EvaluationGateDecision::NotEvaluated
    );
}

#[test]
fn test_evaluation_gate_decision_description() {
    assert_eq!(EvaluationGateDecision::Approved.to_string(), "approved");
    assert_eq!(
        EvaluationGateDecision::NotEvaluated.to_string(),
        "not evaluated — no metrics record available"
    );
}

#[test]
fn test_perception_request_handle_throws_for_missing_file() {
    let worker = MockPerceptionWorker::new(make_classification_result("x", 1.0));
    let request = PerceptionRequest::new("/nonexistent/path/image.jpg");
    assert!(worker.handle(&request).is_err());
}

// MARK: - LocalArtifactStore

#[test]
fn test_artifact_store_writes_and_resolves_blob() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = LocalArtifactStore::new(dir.path()).expect("store");

    let payload = b"hello perception";
    let artifact_ref = store
        .write_with_default_redaction(payload, "application/octet-stream", "test_blob")
        .expect("write artifact");

    assert!(artifact_ref.uri.starts_with("artifacts://"));
    assert!(
        artifact_ref
            .content_hash
            .as_deref()
            .map(|hash| !hash.is_empty())
            .unwrap_or(false)
    );
    assert_eq!(artifact_ref.redaction, "prompt_forbidden");
    assert!(store.resolve(&artifact_ref).is_some());
    assert_eq!(store.read(&artifact_ref).expect("read artifact"), payload);
}

#[test]
fn test_artifact_store_is_idempotent_for_same_content() {
    let dir = tempfile::tempdir().expect("temp dir");
    let store = LocalArtifactStore::new(dir.path()).expect("store");

    let payload = b"stable content";
    let first = store
        .write(payload, "application/octet-stream", "x", "prompt_forbidden")
        .expect("first write");
    let second = store
        .write(payload, "application/octet-stream", "x", "prompt_forbidden")
        .expect("second write");

    assert_eq!(first.content_hash, second.content_hash);
    assert_eq!(first.uri, second.uri);
}

// MARK: - ManifestScanner + PerceptionSchemaValidator

#[test]
fn test_schema_validator_passes_valid_manifest() {
    let manifest = valid_manifest();
    assert!(PerceptionSchemaValidator::validate_manifest(&manifest).is_ok());
}

#[test]
fn test_schema_validator_rejects_unknown_version() {
    let manifest = valid_manifest();
    let manifest = PerceptionModelManifest::with_options(
        "cove.perception.model_manifest.v99".to_string(),
        manifest.model_id,
        manifest.display_name,
        manifest.task,
        manifest.backend_family,
        manifest.runtime,
        manifest.input_contract,
        manifest.output_contract,
        manifest.license,
        manifest.source,
    );

    match PerceptionSchemaValidator::validate_manifest(&manifest) {
        Err(ValidationError::UnsupportedSchemaVersion(version)) => {
            assert!(version.contains("v99"));
        }
        other => panic!("expected unsupportedSchemaVersion, got {other:?}"),
    }
}

#[test]
fn test_manifest_scanner_picks_up_manifest_json() {
    let dir = tempfile::tempdir().expect("temp dir");
    let manifest = valid_manifest();
    let data = serde_json::to_vec(&manifest).expect("encode manifest");
    std::fs::write(dir.path().join("manifest.json"), data).expect("write manifest");

    let result = ManifestScanner::scan(dir.path());
    assert_eq!(result.manifests.len(), 1);
    assert_eq!(result.manifests[0].model_id, "test_classifier_v1");
    assert!(result.errors.is_empty());
}

#[test]
fn test_manifest_scanner_collects_errors_for_invalid_json() {
    let dir = tempfile::tempdir().expect("temp dir");
    std::fs::write(dir.path().join("manifest.json"), b"not valid json")
        .expect("write invalid manifest");

    let result = ManifestScanner::scan(dir.path());
    assert!(result.manifests.is_empty());
    assert_eq!(result.errors.len(), 1);
}

// MARK: - PerceptionWorkerFactory

#[test]
fn test_worker_factory_builds_worker_for_registered_backend() {
    let mut factory = PerceptionWorkerFactory::new();
    let lamp_result = make_classification_result("lamp", 0.9);
    factory.register("test", move |_manifest| {
        Some(Arc::new(MockPerceptionWorker::new(lamp_result.clone())) as Arc<dyn PerceptionWorker>)
    });
    let manifest = manifest_with_backend("test");
    assert!(factory.make_worker(&manifest).is_some());
}

#[test]
fn test_worker_factory_returns_nil_for_unregistered_backend() {
    let factory = PerceptionWorkerFactory::new();
    let manifest = manifest_with_backend("onnxruntime");
    assert!(factory.make_worker(&manifest).is_none());
}
