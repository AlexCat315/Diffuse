//! Crate root. See MIGRATION.md §5.
pub mod core;
pub mod gates;
pub mod support;
pub mod worker;

pub use core::manifest_scanner::{ManifestScanError, ManifestScanner, ScanResult};
pub use core::perception_contracts::{
    ArtifactRef, BBox2D, ClassificationObservation, DetectedObjectObservation,
    ImageEmbeddingObservation, PerceptionDiagnostic, PerceptionEvidence, PerceptionLicenseMetadata,
    PerceptionModelManifest, PerceptionModelSource, PerceptionObservation, PerceptionProvenance,
    PerceptionRequest, PerceptionResult, PerceptionRuntimeConfig, PerceptionSemanticCandidate,
    PerceptionTask, PerceptionTimingInfo,
};
pub use core::perception_schema_validator::{PerceptionSchemaValidator, ValidationError};
pub use core::perception_service::PerceptionService;
pub use gates::evaluation_gate::{
    EvaluationGate, EvaluationGateDecision, ModelMetricsRecord, SwiftDate,
};
pub use gates::license_gate::{
    LicenseGate, LicenseGateDecision, LicenseGatePolicy, PerceptionDistributionMode,
};
pub use support::local_artifact_store::{ArtifactStoreError, LocalArtifactStore};
pub use support::perception_world_event_mapper::{
    InferredWrite, InferredWriteSet, PerceptionWorldEventMapper,
};
pub use worker::apple_vision_perception_worker::AppleVisionPerceptionWorker;
pub use worker::perception_worker::{PerceptionRuntimeError, PerceptionWorker};
pub use worker::perception_worker_factory::{Builder, PerceptionWorkerFactory};
