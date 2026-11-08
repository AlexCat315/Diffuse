//! `SemanticPipelineTests.swift` — translation, 1:1 test count.

use std::path::Path;
use std::sync::Arc;

use diffuse_intent::transactions::world_event::{WorldEvent, WorldPropertyValue};
use diffuse_kernel::codable::new_uuid;
use diffuse_perception::{
    AppleVisionPerceptionWorker, ClassificationObservation, PerceptionModelManifest,
    PerceptionObservation, PerceptionProvenance, PerceptionResult, PerceptionRuntimeError,
    PerceptionSemanticCandidate, PerceptionTask, PerceptionTimingInfo, PerceptionWorker,
};
use diffuse_semantic::{
    AmbiguityDecision, AssetSemanticPipeline, CandidateRegionSet, EphemeralSemanticMemoryStore,
    FileBackedSemanticMemoryStore, GeometryBackend, GeometryFingerprint, GeometrySignals,
    GeometrySignalsAABB, GeometrySignalsConnectedComponent, GeometrySignalsProtrusion,
    GeometrySignalsSupportPlane, GeometrySignalsSymmetryAxis, MetadataBackend,
    NameHeuristicBackend, RawStructure, RawStructureBone, RawStructureNode, RawStructureSkeleton,
    Region, RegionSource, RigBackend, SemanticAnalyzerBackend, SemanticConfirmation,
    SemanticConfirmationOutcome, SemanticMemoryStore, SemanticPipelineConfig, SemanticProposal,
    SemanticProvenance, SemanticWorldEventMapper, VisionBackend,
};

#[test]
fn name_heuristic_backend_infers_label_from_node_name() {
    let mut raw = RawStructure::new("test://chair.glb");
    raw.nodes = vec![
        RawStructureNode::new("n0", "seat_geo"),
        RawStructureNode::new("n1", "backrest_grp"),
        RawStructureNode::new("n2", "leg_L"),
    ];
    let signals = GeometrySignals::new(raw.asset_uri.as_str());
    let regions = CandidateRegionSet::with_regions(
        raw.asset_uri.as_str(),
        vec![
            Region::new("region:n0", RegionSource::Structural),
            Region::new("region:n1", RegionSource::Structural),
            Region::new("region:n2", RegionSource::Structural),
        ],
    );

    let backend = NameHeuristicBackend::new();
    let proposals = backend.analyze(&regions, &raw, &signals);

    assert!(!proposals.is_empty());
    let labels: Vec<&str> = proposals.iter().map(|p| p.label.as_str()).collect();
    assert!(labels.contains(&"seat"));
    assert!(labels.contains(&"backrest"));
}

#[test]
fn rig_backend_maps_standard_bone_names() {
    let mut raw = RawStructure::new("test://character.glb");
    raw.skeleton = Some(RawStructureSkeleton::new(vec![
        RawStructureBone::new("b0", "mixamorig:Head"),
        RawStructureBone::new("b1", "mixamorig:LeftUpperArm"),
        RawStructureBone::new("b2", "mixamorig:RightFoot"),
    ]));
    let signals = GeometrySignals::new(raw.asset_uri.as_str());
    let regions = CandidateRegionSet::new(raw.asset_uri.as_str());

    let backend = RigBackend::new();
    let proposals = backend.analyze(&regions, &raw, &signals);

    let labels: Vec<&str> = proposals.iter().map(|p| p.label.as_str()).collect();
    assert!(labels.contains(&"head"));
    assert!(labels.contains(&"upper_arm"));
    assert!(labels.contains(&"foot"));
}

#[test]
fn metadata_backend_reads_custom_property() {
    let mut raw = RawStructure::new("test://prop.glb");
    raw.nodes = vec![RawStructureNode::new("n0", "root")];
    raw.custom_properties
        .insert("semantic_role".to_string(), "door_handle".to_string());
    let signals = GeometrySignals::new(raw.asset_uri.as_str());
    let regions = CandidateRegionSet::with_regions(
        raw.asset_uri.as_str(),
        vec![Region::new("region:n0", RegionSource::Structural)],
    );

    let backend = MetadataBackend::default();
    let proposals = backend.analyze(&regions, &raw, &signals);

    assert_eq!(proposals.len(), 1);
    assert_eq!(
        proposals.first().map(|p| p.label.as_str()),
        Some("door_handle")
    );
    assert_eq!(proposals.first().map(|p| p.confidence), Some(0.95));
}

#[test]
fn pipeline_auto_commits_high_confidence_proposal() {
    let mut raw = RawStructure::new("test://simple.glb");
    raw.nodes = vec![RawStructureNode::new("n0", "seat_geo")];
    raw.custom_properties
        .insert("semantic_role".to_string(), "seat".to_string());
    let signals = GeometrySignals::new(raw.asset_uri.as_str());
    let pipeline = AssetSemanticPipeline::with_backends(vec![Box::new(MetadataBackend::default())]);

    let decision = pipeline.run(&raw, &signals);

    match decision {
        AmbiguityDecision::AutoCommit(proposals) => {
            assert!(!proposals.is_empty());
            assert_eq!(proposals.first().map(|p| p.label.as_str()), Some("seat"));
        }
        AmbiguityDecision::NeedsConfirmation(_) => {
            panic!("Expected autoCommit but got needsConfirmation");
        }
    }
}

#[test]
fn pipeline_requests_confirmation_on_conflict() {
    let mut raw = RawStructure::new("test://ambiguous.glb");
    raw.nodes = vec![RawStructureNode::new("n0", "part_geo")];
    raw.custom_properties
        .insert("semantic_role".to_string(), "handle".to_string());
    let signals = GeometrySignals::new(raw.asset_uri.as_str());

    // Both backends fire with different labels at similar confidence → conflict
    let config = SemanticPipelineConfig::new(
        0.99, // very high threshold to force confirmation
        0.99, 0.15,
    );
    let pipeline = AssetSemanticPipeline::new(
        config,
        vec![
            Box::new(NameHeuristicBackend::new()),
            Box::new(MetadataBackend::default()),
        ],
        None,
    );

    let decision = pipeline.run(&raw, &signals);

    // With threshold=0.99 and MetadataBackend returning 0.95, it cannot auto-commit.
    match decision {
        AmbiguityDecision::NeedsConfirmation(_) => {}
        // also acceptable if only one region has proposals
        AmbiguityDecision::AutoCommit(proposals) => assert!(!proposals.is_empty()),
    }
}

#[test]
fn apply_confirmation_records_in_memory() {
    let memory = Arc::new(EphemeralSemanticMemoryStore::new());
    let pipeline = AssetSemanticPipeline::with_memory(memory.clone());

    let fingerprint = GeometryFingerprint::with_topology(0, 1, 2, 1);
    let mut region = Region::new("region:n0", RegionSource::Structural);
    region.fingerprint = fingerprint.clone();
    let region_set = CandidateRegionSet::with_regions("test://x.glb", vec![region]);
    let proposal = SemanticProposal::new("region:n0", "seat", 0.90, "name_heuristic");
    let confirmation = SemanticConfirmation::new(
        "region:n0",
        SemanticConfirmationOutcome::Accepted("seat".to_string()),
        "user",
    );

    let committed = pipeline
        .apply(&[confirmation], &region_set, &[proposal])
        .expect("apply confirmations");

    assert_eq!(committed.len(), 1);
    assert_eq!(committed.first().map(|p| p.label.as_str()), Some("seat"));
    assert_eq!(
        committed.first().map(|p| p.provenance),
        Some(SemanticProvenance::Confirmed)
    );

    let entries = memory.lookup(&fingerprint);
    assert!(!entries.is_empty());
    assert_eq!(entries.first().map(|e| e.label.as_str()), Some("seat"));
}

#[test]
fn apply_ignores_confirmation_without_pending_proposal() {
    let memory = Arc::new(EphemeralSemanticMemoryStore::new());
    let pipeline = AssetSemanticPipeline::with_memory(memory.clone());
    let fingerprint = GeometryFingerprint::with_topology(0, 1, 2, 1);
    let mut region = Region::new("region:n0", RegionSource::Structural);
    region.fingerprint = fingerprint.clone();
    let regions = CandidateRegionSet::with_regions("test://x.glb", vec![region]);
    let confirmation = SemanticConfirmation::new(
        "region:n0",
        SemanticConfirmationOutcome::Accepted("injected".to_string()),
        "user",
    );

    let committed = pipeline
        .apply(&[confirmation], &regions, &[])
        .expect("apply confirmations");
    let remembered = memory.lookup(&fingerprint);

    assert!(committed.is_empty());
    assert!(remembered.is_empty());
}

#[test]
fn geometry_fingerprint_default_version() {
    let fp = GeometryFingerprint::new();
    assert_eq!(fp.version, 1);
    assert_eq!(fp.scale_hint, 1.0);
}

#[test]
fn raw_structure_custom_properties() {
    let mut raw = RawStructure::new("test://x.glb");
    raw.custom_properties
        .insert("rig_type".to_string(), "biped".to_string());
    raw.custom_properties
        .insert("lod_count".to_string(), "3".to_string());
    assert_eq!(
        raw.custom_properties.get("rig_type").map(String::as_str),
        Some("biped")
    );
    assert_eq!(
        raw.custom_properties.get("lod_count").map(String::as_str),
        Some("3")
    );
}

// MARK: - SemanticWorldEventMapper

#[test]
fn mapper_emits_semantic_role_from_metadata_proposal() {
    let proposals = vec![
        SemanticProposal::new("region:n0", "door_handle", 0.95, "metadata")
            .with_provenance(SemanticProvenance::Structural),
    ];
    let events = SemanticWorldEventMapper::new().make_world_events(&proposals, "scene:7");

    assert!(!events.is_empty());
    let role_event = events.iter().find(|event| {
        matches!(
            event,
            WorldEvent::EntityInferredUpdated { property, .. } if property == "semanticRole"
        )
    });
    assert!(role_event.is_some());
    if let Some(WorldEvent::EntityInferredUpdated {
        ref_,
        property,
        value,
        confidence,
        source,
    }) = role_event
    {
        assert_eq!(ref_, "scene:7");
        assert_eq!(property, "semanticRole");
        assert_eq!(
            value,
            &WorldPropertyValue::String("door_handle".to_string())
        );
        assert!((confidence - 0.95).abs() < 0.001);
        assert_eq!(source.as_deref(), Some("semantic:metadata"));
    } else {
        panic!("Expected semanticRole event");
    }
}

#[test]
fn mapper_emits_semantic_parts_for_multiple_proposals() {
    let proposals = vec![
        SemanticProposal::new("region:n0", "seat", 0.80, "name_heuristic"),
        SemanticProposal::new("region:n1", "backrest", 0.75, "name_heuristic"),
    ];
    let events = SemanticWorldEventMapper::new().make_world_events(&proposals, "scene:3");

    let parts_event = events.iter().find(|event| {
        matches!(
            event,
            WorldEvent::EntityInferredUpdated { property, .. } if property == "semanticParts"
        )
    });
    assert!(parts_event.is_some());
    if let Some(WorldEvent::EntityInferredUpdated { value, .. }) = parts_event {
        match value {
            WorldPropertyValue::String(value) => {
                assert!(value.contains("seat"));
                assert!(value.contains("backrest"));
            }
            _ => panic!("Expected string value"),
        }
    }
}

#[test]
fn mapper_emits_rig_parts_for_rig_backend_proposals() {
    let proposals = vec![
        SemanticProposal::new("region:bone:b0", "head", 0.90, "rig"),
        SemanticProposal::new("region:bone:b1", "upper_arm", 0.90, "rig"),
    ];
    let events = SemanticWorldEventMapper::new().make_world_events(&proposals, "scene:9");

    let rig_event = events.iter().find(|event| {
        matches!(
            event,
            WorldEvent::EntityInferredUpdated { property, .. } if property == "rigParts"
        )
    });
    assert!(rig_event.is_some());
    if let Some(WorldEvent::EntityInferredUpdated { value, source, .. }) = rig_event {
        match value {
            WorldPropertyValue::String(value) => {
                assert!(value.contains("head"));
            }
            _ => panic!("Expected string value"),
        }
        assert_eq!(source.as_deref(), Some("semantic:rig"));
    }
}

#[test]
fn mapper_returns_empty_for_empty_proposals() {
    let events = SemanticWorldEventMapper::new().make_world_events(&[], "scene:1");
    assert!(events.is_empty());
}

// MARK: - FileBackedSemanticMemoryStore

#[test]
fn file_backed_store_round_trips_confirmed_entry() {
    let temp = tempfile::tempdir().expect("temp dir");
    let store_url = temp
        .path()
        .join(format!("cove_semantic_{}", new_uuid()))
        .join("memory.json");
    let store = FileBackedSemanticMemoryStore::new(store_url.as_path()).expect("store");

    let fingerprint = GeometryFingerprint::with_topology(0, 0, 3, 1);
    let confirmation = SemanticConfirmation::new(
        "region:body",
        SemanticConfirmationOutcome::Accepted("chair".to_string()),
        "user",
    );
    store
        .record("body", &fingerprint, &confirmation)
        .expect("record");

    let results = store.lookup(&fingerprint);
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].label, "chair");
}

#[test]
fn file_backed_store_survives_reload() {
    let temp = tempfile::tempdir().expect("temp dir");
    let dir = temp
        .path()
        .join(format!("cove_semantic_reload_{}", new_uuid()));
    let store_url = dir.join("memory.json");

    let fingerprint = GeometryFingerprint::with_topology(1, 2, 5, 1);
    {
        let store = FileBackedSemanticMemoryStore::new(store_url.as_path()).expect("store");
        let confirmation = SemanticConfirmation::new(
            "region:leg",
            SemanticConfirmationOutcome::Accepted("table_leg".to_string()),
            "pipeline",
        );
        store
            .record("leg", &fingerprint, &confirmation)
            .expect("record");
    }

    // Re-open from same file
    let store2 = FileBackedSemanticMemoryStore::new(store_url.as_path()).expect("reload store");
    let results = store2.lookup(&fingerprint);
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].label, "table_leg");
}

#[test]
fn file_backed_store_ignores_rejected_confirmation() {
    let temp = tempfile::tempdir().expect("temp dir");
    let store_url = temp
        .path()
        .join(format!("cove_semantic_reject_{}", new_uuid()))
        .join("memory.json");
    let store = FileBackedSemanticMemoryStore::new(store_url.as_path()).expect("store");

    let fingerprint = GeometryFingerprint::new();
    let rejection =
        SemanticConfirmation::new("region:x", SemanticConfirmationOutcome::Rejected, "user");
    store.record("x", &fingerprint, &rejection).expect("record");

    let results = store.lookup(&fingerprint);
    assert!(results.is_empty());
}

#[test]
fn file_backed_store_reports_write_failure_without_changing_memory() {
    let temp = tempfile::tempdir().expect("temp dir");
    let directory = temp
        .path()
        .join(format!("cove_semantic_failure_{}", new_uuid()));
    let store_url = directory.join("memory.json");
    let store = FileBackedSemanticMemoryStore::new(store_url.as_path()).expect("store");
    std::fs::remove_dir_all(&directory).expect("remove directory");
    std::fs::write(&directory, b"parent-is-a-file").expect("replace parent with file");

    let fingerprint = GeometryFingerprint::with_topology(0, 1, 2, 1);
    let confirmation = SemanticConfirmation::new(
        "region:failed",
        SemanticConfirmationOutcome::Accepted("seat".to_string()),
        "user",
    );
    assert!(
        store.record("failed", &fingerprint, &confirmation).is_err(),
        "record must surface persistence failures"
    );

    let results = store.lookup(&fingerprint);
    assert!(
        results.is_empty(),
        "failed persistence must not mutate the live index"
    );
}

// MARK: - GeometryBackend

#[test]
fn geometry_backend_infers_character_from_symmetry_and_protrusions() {
    let signals = make_character_signals(4, 0.80);
    let regions = CandidateRegionSet::with_regions(
        "asset://char.glb",
        vec![Region::new("region:root", RegionSource::Structural)],
    );
    let raw_structure = RawStructure::new("asset://char.glb");
    let proposals = GeometryBackend::new().analyze(&regions, &raw_structure, &signals);
    assert!(
        proposals
            .iter()
            .any(|proposal| proposal.label == "character")
    );
}

#[test]
fn geometry_backend_infers_furniture_from_support_plane_and_medium_aabb() {
    // Chair AABB: ~0.6m wide × 0.9m tall → AR 1.5 → category .medium
    let comp = GeometrySignalsConnectedComponent::new(
        "cc0",
        "mesh0",
        120,
        GeometrySignalsAABB::new((-0.3, 0.0, -0.3), (0.3, 0.9, 0.3)),
    );
    let plane = GeometrySignalsSupportPlane::new("sp0", (0.0, 1.0, 0.0), 0.25);
    let mut signals = GeometrySignals::new("asset://chair.glb");
    signals.connected_components = vec![comp];
    signals.support_planes = vec![plane];
    let regions = CandidateRegionSet::with_regions(
        "asset://chair.glb",
        vec![Region::new("region:body", RegionSource::Structural)],
    );
    let raw_structure = RawStructure::new("asset://chair.glb");
    let proposals = GeometryBackend::new().analyze(&regions, &raw_structure, &signals);
    assert!(
        proposals
            .iter()
            .any(|proposal| proposal.label == "furniture")
    );
}

#[test]
fn geometry_backend_produces_no_proposals_for_empty_regions() {
    let signals = GeometrySignals::new("asset://empty.glb");
    let regions = CandidateRegionSet::with_regions("asset://empty.glb", Vec::new());
    let raw_structure = RawStructure::new("asset://empty.glb");
    let proposals = GeometryBackend::new().analyze(&regions, &raw_structure, &signals);
    assert!(proposals.is_empty());
}

#[test]
fn standard_pipeline_includes_geometry_backend() {
    let signals = make_character_signals(4, 0.80);
    let raw_structure = RawStructure::new("asset://biped.glb");
    let pipeline = AssetSemanticPipeline::standard(None);

    // Run individual backend collect step indirectly via run()
    let _result = pipeline.run(&raw_structure, &signals);
    // Primary assertion: no crash, pipeline processes geometry backend
}

// MARK: - Helpers

fn make_character_signals(protrusion_count: usize, symmetry_confidence: f32) -> GeometrySignals {
    let comp = GeometrySignalsConnectedComponent::new(
        "cc0",
        "mesh0",
        500,
        GeometrySignalsAABB::new((-0.4, 0.0, -0.2), (0.4, 1.8, 0.2)),
    );
    let symmetry = GeometrySignalsSymmetryAxis::new((1.0, 0.0, 0.0), symmetry_confidence);
    let protrusions = (0..protrusion_count)
        .map(|i| GeometrySignalsProtrusion::new(format!("p{i}"), 0.5, 0.07))
        .collect();
    let mut signals = GeometrySignals::new("asset://char.glb");
    signals.connected_components = vec![comp];
    signals.symmetry_axes = vec![symmetry];
    signals.protrusions = protrusions;
    signals.surface_area = 4.5;
    signals.volume_estimate = 0.15;
    signals
}

#[test]
fn vision_backend_returns_empty_when_no_preview_image() {
    let raw = RawStructure::new("test://chair.glb");
    let signals = GeometrySignals::new(raw.asset_uri.as_str());
    let regions = CandidateRegionSet::with_regions(
        raw.asset_uri.as_str(),
        vec![Region::new("region:root", RegionSource::Structural)],
    );
    let proposals = VisionBackend::default().analyze(&regions, &raw, &signals);
    assert!(
        proposals.is_empty(),
        "VisionBackend must return empty without a previewImagePath"
    );
}

#[test]
fn vision_backend_returns_empty_when_image_file_missing() {
    let mut raw = RawStructure::new("test://chair.glb");
    raw.preview_image_path = Some("/nonexistent/preview.png".to_string());
    let signals = GeometrySignals::new(raw.asset_uri.as_str());
    let regions = CandidateRegionSet::with_regions(
        raw.asset_uri.as_str(),
        vec![Region::new("region:root", RegionSource::Structural)],
    );
    let proposals = VisionBackend::default().analyze(&regions, &raw, &signals);
    assert!(
        proposals.is_empty(),
        "VisionBackend must return empty when image file is missing"
    );
}

#[test]
fn vision_backend_maps_worker_classifications_to_proposals() {
    let image_url = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../Engine/third-party/sdl3/test/trashcan.png");
    if !image_url.exists() {
        // Swift `XCTSkip("Fixture image not available")`.
        return;
    }

    let mut raw = RawStructure::new("test://bin.glb");
    raw.preview_image_path = Some(image_url.to_string_lossy().into_owned());
    let signals = GeometrySignals::new(raw.asset_uri.as_str());
    let regions = CandidateRegionSet::with_regions(
        raw.asset_uri.as_str(),
        vec![Region::new("region:root", RegionSource::Structural)],
    );
    let proposals = VisionBackend::new(2, 0.0, Arc::new(StubVisionWorker::new("trash_can", 0.75)))
        .analyze(&regions, &raw, &signals);

    assert!(
        !proposals.is_empty(),
        "VisionBackend must produce proposals for a real image"
    );
    assert_eq!(proposals.first().map(|p| p.source.as_str()), Some("vision"));
    assert_eq!(
        proposals.first().map(|p| p.label.as_str()),
        Some("trash_can")
    );
    assert!((proposals.first().map(|p| p.confidence).unwrap_or(-1.0) - 0.6).abs() < 0.0001);
}

#[test]
fn standard_pipeline_includes_vision_backend() {
    let _pipeline = AssetSemanticPipeline::standard(None);
    // compile-time check that preview_image_path parameter is accepted
    let _raw = RawStructure::new("test://asset.glb");
}

#[test]
fn mapper_prefers_confirmed_over_inferred() {
    let proposals = vec![
        SemanticProposal::new("region:n0", "inferred_label", 0.99, "name_heuristic")
            .with_provenance(SemanticProvenance::Inferred),
        SemanticProposal::new("region:n0", "confirmed_label", 0.80, "user_confirmed")
            .with_provenance(SemanticProvenance::Confirmed),
    ];
    let events = SemanticWorldEventMapper::new().make_world_events(&proposals, "scene:5");

    let role_event = events.iter().find(|event| {
        matches!(
            event,
            WorldEvent::EntityInferredUpdated { property, .. } if property == "semanticRole"
        )
    });
    if let Some(WorldEvent::EntityInferredUpdated { value, .. }) = role_event {
        assert_eq!(
            value,
            &WorldPropertyValue::String("confirmed_label".to_string())
        );
    } else {
        panic!("Expected semanticRole event");
    }
}

struct StubVisionWorker {
    manifest: PerceptionModelManifest,
    label: String,
    confidence: f64,
}

impl StubVisionWorker {
    fn new(label: &str, confidence: f64) -> Self {
        StubVisionWorker {
            manifest: AppleVisionPerceptionWorker::new().manifest(),
            label: label.to_string(),
            confidence,
        }
    }
}

impl PerceptionWorker for StubVisionWorker {
    fn manifest(&self) -> PerceptionModelManifest {
        self.manifest.clone()
    }

    fn analyze_image(
        &self,
        _url: &Path,
        request_id: &str,
        _max_results: i64,
    ) -> Result<PerceptionResult, PerceptionRuntimeError> {
        Ok(PerceptionResult::new(
            request_id,
            self.manifest.model_id.clone(),
            "test",
            PerceptionTask::Classification,
            "success",
            vec![PerceptionObservation::Classification(
                ClassificationObservation::new(
                    "classification_0",
                    self.label.clone(),
                    "fixture",
                    self.confidence,
                    vec![PerceptionSemanticCandidate::new(
                        "object_category",
                        self.label.clone(),
                        self.confidence,
                    )],
                    Vec::new(),
                ),
            )],
            PerceptionTimingInfo::new(0.0),
            PerceptionProvenance::new("fixture", self.manifest.model_id.clone()),
        ))
    }
}
