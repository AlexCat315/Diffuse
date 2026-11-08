//! `PerceptionContracts.swift` — structured perception input, model manifests and results.
//!
//! Persisted JSON matches Swift `Codable` (MIGRATION.md §5.4): synthesized member-wise
//! camelCase keys, optional properties omitted rather than written as `null`, and
//! Swift's own text formatting for `Float`/`Double` numbers.

use std::collections::BTreeMap;

use diffuse_kernel::codable::{new_uuid, serialize_double, serialize_float};
use serde::{Deserialize, Serialize};

/// Structured input to a `PerceptionWorker`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PerceptionRequest {
    pub request_id: String,
    pub task: PerceptionTask,
    /// Local `file://` or `artifacts://` URI for the input image.
    pub input_uri: String,
    pub max_results: i64,
    #[serde(serialize_with = "serialize_float")]
    pub confidence_threshold: f32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub locale: Option<String>,
    /// Freeform hints forwarded to the backend (e.g. `"category_hint": "furniture"`).
    pub hints: BTreeMap<String, String>,
}

impl PerceptionRequest {
    /// Swift `init(inputURI:task:maxResults:confidenceThreshold:locale:hints:)` with
    /// the `requestID` default.
    pub fn new(input_uri: impl Into<String>) -> Self {
        Self::with_options(
            new_uuid(),
            PerceptionTask::Classification,
            input_uri,
            5,
            0.5,
            None,
            BTreeMap::new(),
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn with_options(
        request_id: String,
        task: PerceptionTask,
        input_uri: impl Into<String>,
        max_results: i64,
        confidence_threshold: f32,
        locale: Option<String>,
        hints: BTreeMap<String, String>,
    ) -> Self {
        PerceptionRequest {
            request_id,
            task,
            input_uri: input_uri.into(),
            max_results,
            confidence_threshold,
            locale,
            hints,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PerceptionTask {
    #[default]
    Classification,
    ObjectDetection,
    InstanceSegmentation,
    SemanticSegmentation,
    DepthEstimation,
    ImageEmbedding,
    TextImageGrounding,
}

impl PerceptionTask {
    /// Swift `rawValue`.
    pub const fn as_str(self) -> &'static str {
        match self {
            PerceptionTask::Classification => "classification",
            PerceptionTask::ObjectDetection => "object_detection",
            PerceptionTask::InstanceSegmentation => "instance_segmentation",
            PerceptionTask::SemanticSegmentation => "semantic_segmentation",
            PerceptionTask::DepthEstimation => "depth_estimation",
            PerceptionTask::ImageEmbedding => "image_embedding",
            PerceptionTask::TextImageGrounding => "text_image_grounding",
        }
    }
}

impl std::fmt::Display for PerceptionTask {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.as_str())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PerceptionRuntimeConfig {
    pub preferred_runtime: String,
    pub fallback_runtimes: Vec<String>,
    pub device_policy: Vec<String>,
}

impl PerceptionRuntimeConfig {
    pub fn new(preferred_runtime: impl Into<String>) -> Self {
        Self::with_options(preferred_runtime, Vec::new(), vec!["cpu".to_string()])
    }

    pub fn with_options(
        preferred_runtime: impl Into<String>,
        fallback_runtimes: Vec<String>,
        device_policy: Vec<String>,
    ) -> Self {
        PerceptionRuntimeConfig {
            preferred_runtime: preferred_runtime.into(),
            fallback_runtimes,
            device_policy,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PerceptionLicenseMetadata {
    pub code_license: String,
    pub weights_license: String,
    pub dataset_lineage: Vec<String>,
    pub commercial_use: String,
    pub redistribution: String,
    pub requires_attribution: bool,
    pub requires_share_alike: bool,
    pub non_commercial_only: bool,
}

impl PerceptionLicenseMetadata {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        code_license: impl Into<String>,
        weights_license: impl Into<String>,
        dataset_lineage: Vec<String>,
        commercial_use: impl Into<String>,
        redistribution: impl Into<String>,
        requires_attribution: bool,
        requires_share_alike: bool,
        non_commercial_only: bool,
    ) -> Self {
        PerceptionLicenseMetadata {
            code_license: code_license.into(),
            weights_license: weights_license.into(),
            dataset_lineage,
            commercial_use: commercial_use.into(),
            redistribution: redistribution.into(),
            requires_attribution,
            requires_share_alike,
            non_commercial_only,
        }
    }

    /// Swift's member-wise defaults for the three optional flags.
    pub fn with_defaults(
        code_license: impl Into<String>,
        weights_license: impl Into<String>,
        dataset_lineage: Vec<String>,
        commercial_use: impl Into<String>,
        redistribution: impl Into<String>,
    ) -> Self {
        Self::new(
            code_license,
            weights_license,
            dataset_lineage,
            commercial_use,
            redistribution,
            false,
            false,
            false,
        )
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PerceptionModelSource {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub training_repo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub export_tool: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub export_commit: Option<String>,
}

impl PerceptionModelSource {
    pub fn with_options(
        training_repo: Option<String>,
        commit: Option<String>,
        export_tool: Option<String>,
        export_commit: Option<String>,
    ) -> Self {
        PerceptionModelSource {
            training_repo,
            commit,
            export_tool,
            export_commit,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PerceptionModelManifest {
    pub schema_version: String,
    pub model_id: String,
    pub display_name: String,
    pub task: PerceptionTask,
    pub backend_family: String,
    pub runtime: PerceptionRuntimeConfig,
    pub input_contract: String,
    pub output_contract: String,
    pub license: PerceptionLicenseMetadata,
    pub source: PerceptionModelSource,
}

/// Swift's default `schemaVersion` for model manifests.
pub const MODEL_MANIFEST_SCHEMA_VERSION: &str = "cove.perception.model_manifest.v1";
/// Swift's default `schemaVersion` for results.
pub const RESULT_SCHEMA_VERSION: &str = "cove.perception.result.v1";

impl PerceptionModelManifest {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        model_id: impl Into<String>,
        display_name: impl Into<String>,
        task: PerceptionTask,
        backend_family: impl Into<String>,
        runtime: PerceptionRuntimeConfig,
        input_contract: impl Into<String>,
        output_contract: impl Into<String>,
        license: PerceptionLicenseMetadata,
    ) -> Self {
        Self::with_options(
            MODEL_MANIFEST_SCHEMA_VERSION.to_string(),
            model_id,
            display_name,
            task,
            backend_family,
            runtime,
            input_contract,
            output_contract,
            license,
            PerceptionModelSource::default(),
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn with_options(
        schema_version: String,
        model_id: impl Into<String>,
        display_name: impl Into<String>,
        task: PerceptionTask,
        backend_family: impl Into<String>,
        runtime: PerceptionRuntimeConfig,
        input_contract: impl Into<String>,
        output_contract: impl Into<String>,
        license: PerceptionLicenseMetadata,
        source: PerceptionModelSource,
    ) -> Self {
        PerceptionModelManifest {
            schema_version,
            model_id: model_id.into(),
            display_name: display_name.into(),
            task,
            backend_family: backend_family.into(),
            runtime,
            input_contract: input_contract.into(),
            output_contract: output_contract.into(),
            license,
            source,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtifactRef {
    pub uri: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_hash: Option<String>,
    pub media_type: String,
    pub semantic_kind: String,
    pub redaction: String,
}

impl ArtifactRef {
    pub fn new(
        uri: impl Into<String>,
        content_hash: Option<String>,
        media_type: impl Into<String>,
        semantic_kind: impl Into<String>,
    ) -> Self {
        Self::with_options(
            uri,
            content_hash,
            media_type,
            semantic_kind,
            "prompt_forbidden".to_string(),
        )
    }

    pub fn with_options(
        uri: impl Into<String>,
        content_hash: Option<String>,
        media_type: impl Into<String>,
        semantic_kind: impl Into<String>,
        redaction: impl Into<String>,
    ) -> Self {
        ArtifactRef {
            uri: uri.into(),
            content_hash,
            media_type: media_type.into(),
            semantic_kind: semantic_kind.into(),
            redaction: redaction.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PerceptionSemanticCandidate {
    pub kind: String,
    pub label: String,
    #[serde(serialize_with = "serialize_double")]
    pub confidence: f64,
}

impl PerceptionSemanticCandidate {
    pub fn new(kind: impl Into<String>, label: impl Into<String>, confidence: f64) -> Self {
        PerceptionSemanticCandidate {
            kind: kind.into(),
            label: label.into(),
            confidence,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PerceptionEvidence {
    pub kind: String,
    pub source: String,
    #[serde(serialize_with = "serialize_double")]
    pub confidence: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl PerceptionEvidence {
    pub fn new(
        kind: impl Into<String>,
        source: impl Into<String>,
        confidence: f64,
        detail: Option<String>,
    ) -> Self {
        PerceptionEvidence {
            kind: kind.into(),
            source: source.into(),
            confidence,
            detail,
        }
    }
}

/// One observation in a perception result.
///
/// Swift's hand-written `CodingKeys` encode this as
/// `{"kind": "object_detection", "payload": {…}}`; serde's adjacent tagging with
/// the same key names reproduces those bytes.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "payload", rename_all = "snake_case")]
pub enum PerceptionObservation {
    Classification(ClassificationObservation),
    ObjectDetection(DetectedObjectObservation),
    ImageEmbedding(ImageEmbeddingObservation),
}

impl PerceptionObservation {
    /// Swift `id`.
    pub fn id(&self) -> &str {
        match self {
            PerceptionObservation::Classification(observation) => &observation.id,
            PerceptionObservation::ObjectDetection(observation) => &observation.id,
            PerceptionObservation::ImageEmbedding(observation) => &observation.id,
        }
    }

    /// Swift `primaryCandidate`.
    pub fn primary_candidate(&self) -> Option<&PerceptionSemanticCandidate> {
        match self {
            PerceptionObservation::Classification(observation) => {
                observation.semantic_candidates.first()
            }
            PerceptionObservation::ObjectDetection(observation) => {
                observation.semantic_candidates.first()
            }
            PerceptionObservation::ImageEmbedding(_) => None,
        }
    }
}

/// Pixel-space bounding box (origin at top-left).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BBox2D {
    #[serde(serialize_with = "serialize_float")]
    pub x: f32,
    #[serde(serialize_with = "serialize_float")]
    pub y: f32,
    #[serde(serialize_with = "serialize_float")]
    pub width: f32,
    #[serde(serialize_with = "serialize_float")]
    pub height: f32,
}

impl BBox2D {
    pub fn new(x: f32, y: f32, width: f32, height: f32) -> Self {
        BBox2D {
            x,
            y,
            width,
            height,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DetectedObjectObservation {
    pub id: String,
    pub label: String,
    pub label_space: String,
    #[serde(serialize_with = "serialize_double")]
    pub confidence: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bbox2_d: Option<BBox2D>,
    pub semantic_candidates: Vec<PerceptionSemanticCandidate>,
    pub evidence: Vec<PerceptionEvidence>,
}

impl DetectedObjectObservation {
    pub fn new(
        id: impl Into<String>,
        label: impl Into<String>,
        label_space: impl Into<String>,
        confidence: f64,
        bbox2_d: Option<BBox2D>,
        semantic_candidates: Vec<PerceptionSemanticCandidate>,
        evidence: Vec<PerceptionEvidence>,
    ) -> Self {
        DetectedObjectObservation {
            id: id.into(),
            label: label.into(),
            label_space: label_space.into(),
            confidence,
            bbox2_d,
            semantic_candidates,
            evidence,
        }
    }
}

/// An image embedding produced by a vision-language model.
///
/// The raw vector is stored in `embedding_ref` (`ArtifactRef`, prompt_forbidden).
/// A session only sees that an embedding exists, not the vector itself.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageEmbeddingObservation {
    pub id: String,
    /// Handle to the embedding vector in the artifact store (prompt_forbidden).
    pub embedding_ref: ArtifactRef,
    pub model_id: String,
    pub vector_space_id: String,
    pub normalization: String,
    pub evidence: Vec<PerceptionEvidence>,
}

impl ImageEmbeddingObservation {
    pub fn new(
        id: impl Into<String>,
        embedding_ref: ArtifactRef,
        model_id: impl Into<String>,
        vector_space_id: impl Into<String>,
    ) -> Self {
        Self::with_options(
            id,
            embedding_ref,
            model_id,
            vector_space_id,
            "l2".to_string(),
            Vec::new(),
        )
    }

    pub fn with_options(
        id: impl Into<String>,
        embedding_ref: ArtifactRef,
        model_id: impl Into<String>,
        vector_space_id: impl Into<String>,
        normalization: impl Into<String>,
        evidence: Vec<PerceptionEvidence>,
    ) -> Self {
        ImageEmbeddingObservation {
            id: id.into(),
            embedding_ref,
            model_id: model_id.into(),
            vector_space_id: vector_space_id.into(),
            normalization: normalization.into(),
            evidence,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClassificationObservation {
    pub id: String,
    pub label: String,
    pub label_space: String,
    #[serde(serialize_with = "serialize_double")]
    pub confidence: f64,
    pub semantic_candidates: Vec<PerceptionSemanticCandidate>,
    pub evidence: Vec<PerceptionEvidence>,
}

impl ClassificationObservation {
    pub fn new(
        id: impl Into<String>,
        label: impl Into<String>,
        label_space: impl Into<String>,
        confidence: f64,
        semantic_candidates: Vec<PerceptionSemanticCandidate>,
        evidence: Vec<PerceptionEvidence>,
    ) -> Self {
        ClassificationObservation {
            id: id.into(),
            label: label.into(),
            label_space: label_space.into(),
            confidence,
            semantic_candidates,
            evidence,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PerceptionDiagnostic {
    pub severity: String,
    pub message: String,
}

impl PerceptionDiagnostic {
    pub fn new(severity: impl Into<String>, message: impl Into<String>) -> Self {
        PerceptionDiagnostic {
            severity: severity.into(),
            message: message.into(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PerceptionTimingInfo {
    #[serde(serialize_with = "serialize_double")]
    pub total_milliseconds: f64,
}

impl PerceptionTimingInfo {
    pub fn new(total_milliseconds: f64) -> Self {
        PerceptionTimingInfo { total_milliseconds }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PerceptionProvenance {
    pub source: String,
    pub model_id: String,
}

impl PerceptionProvenance {
    pub fn new(source: impl Into<String>, model_id: impl Into<String>) -> Self {
        PerceptionProvenance {
            source: source.into(),
            model_id: model_id.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PerceptionResult {
    pub schema_version: String,
    pub request_id: String,
    pub model_id: String,
    pub model_version: String,
    pub task: PerceptionTask,
    pub status: String,
    pub observations: Vec<PerceptionObservation>,
    pub artifacts: Vec<ArtifactRef>,
    pub diagnostics: Vec<PerceptionDiagnostic>,
    pub timing: PerceptionTimingInfo,
    pub provenance: PerceptionProvenance,
}

impl PerceptionResult {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        request_id: impl Into<String>,
        model_id: impl Into<String>,
        model_version: impl Into<String>,
        task: PerceptionTask,
        status: impl Into<String>,
        observations: Vec<PerceptionObservation>,
        timing: PerceptionTimingInfo,
        provenance: PerceptionProvenance,
    ) -> Self {
        Self::with_options(
            RESULT_SCHEMA_VERSION.to_string(),
            request_id,
            model_id,
            model_version,
            task,
            status,
            observations,
            Vec::new(),
            Vec::new(),
            timing,
            provenance,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn with_options(
        schema_version: String,
        request_id: impl Into<String>,
        model_id: impl Into<String>,
        model_version: impl Into<String>,
        task: PerceptionTask,
        status: impl Into<String>,
        observations: Vec<PerceptionObservation>,
        artifacts: Vec<ArtifactRef>,
        diagnostics: Vec<PerceptionDiagnostic>,
        timing: PerceptionTimingInfo,
        provenance: PerceptionProvenance,
    ) -> Self {
        PerceptionResult {
            schema_version,
            request_id: request_id.into(),
            model_id: model_id.into(),
            model_version: model_version.into(),
            task,
            status: status.into(),
            observations,
            artifacts,
            diagnostics,
            timing,
            provenance,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn observation_uses_swift_adjacent_coding_keys() {
        let observation = PerceptionObservation::ImageEmbedding(ImageEmbeddingObservation::new(
            "emb_0",
            ArtifactRef::new(
                "artifacts://embed/0",
                None,
                "application/octet-stream",
                "embedding",
            ),
            "openclip_vit_b32",
            "openclip_vit_b32",
        ));
        let encoded = serde_json::to_string(&observation).expect("encode observation");
        assert!(encoded.starts_with(r#"{"kind":"image_embedding","payload":{"#));
        let decoded: PerceptionObservation =
            serde_json::from_str(&encoded).expect("decode observation");
        assert_eq!(decoded, observation);
    }

    #[test]
    fn detection_observation_keeps_swift_member_names() {
        let observation = PerceptionObservation::ObjectDetection(DetectedObjectObservation::new(
            "det_0",
            "chair",
            "coco_80",
            0.92,
            Some(BBox2D::new(5.0, 10.0, 100.0, 120.0)),
            Vec::new(),
            Vec::new(),
        ));
        let value = serde_json::to_value(&observation).expect("encode observation");
        let payload = &value["payload"];
        assert_eq!(payload["labelSpace"], "coco_80");
        assert_eq!(payload["bbox2D"]["width"], 100.0);
        assert_eq!(payload["confidence"], 0.92);
    }
}
