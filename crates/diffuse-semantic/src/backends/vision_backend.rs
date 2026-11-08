//! `VisionBackend.swift` — Apple Vision classifier proposals from a preview image.

use std::path::PathBuf;
use std::sync::Arc;

use diffuse_kernel::codable::new_uuid;
use diffuse_perception::{AppleVisionPerceptionWorker, PerceptionObservation, PerceptionWorker};

use crate::backends::semantic_analyzer_backend::SemanticAnalyzerBackend;
use crate::semantic_contracts::{
    CandidateRegionSet, GeometrySignals, RawStructure, RegionSource, SemanticProposal,
    SemanticProvenance,
};

/// Uses the Apple Vision image classifier (via `AppleVisionPerceptionWorker`) to produce
/// top-level semantic category proposals from a preview image of the asset.
///
/// Requires `raw_structure.preview_image_path` to be set; returns an empty array when absent
/// or when running on a platform without Vision framework support.
pub struct VisionBackend {
    max_results: i64,
    confidence_threshold: f32,
    worker: Arc<dyn PerceptionWorker>,
}

impl VisionBackend {
    pub fn new(
        max_results: i64,
        confidence_threshold: f32,
        worker: Arc<dyn PerceptionWorker>,
    ) -> Self {
        VisionBackend {
            max_results,
            confidence_threshold,
            worker,
        }
    }

    /// Swift's defaulted initializer: 3 results, 0.40 threshold, Apple Vision worker.
    pub fn with_defaults() -> Self {
        VisionBackend::new(3, 0.40, Arc::new(AppleVisionPerceptionWorker::new()))
    }
}

impl Default for VisionBackend {
    fn default() -> Self {
        VisionBackend::with_defaults()
    }
}

impl SemanticAnalyzerBackend for VisionBackend {
    fn backend_id(&self) -> &'static str {
        "vision"
    }

    fn analyze(
        &self,
        regions: &CandidateRegionSet,
        raw_structure: &RawStructure,
        _signals: &GeometrySignals,
    ) -> Vec<SemanticProposal> {
        let Some(image_path) = raw_structure.preview_image_path.as_deref() else {
            return Vec::new();
        };
        if image_path.is_empty() {
            return Vec::new();
        }

        let path: PathBuf = match image_path.strip_prefix("file://") {
            Some(path) => PathBuf::from(path),
            None => PathBuf::from(image_path),
        };
        if !path.exists() {
            return Vec::new();
        }

        let result = match self
            .worker
            .analyze_image_async(&path, &new_uuid(), self.max_results)
        {
            Ok(result) => result,
            Err(_error) => return Vec::new(),
        };

        // Map the top classification observations to proposals on all root-level regions.
        let root_regions: Vec<_> = regions
            .regions
            .iter()
            .filter(|region| {
                region.source == RegionSource::Structural && region.parent_region_id.is_none()
            })
            .collect();
        if root_regions.is_empty() {
            return Vec::new();
        }

        let mut proposals = Vec::new();
        for observation in &result.observations {
            let PerceptionObservation::Classification(obs) = observation else {
                continue;
            };
            let Some(candidate) = obs.semantic_candidates.first() else {
                continue;
            };
            if (candidate.confidence as f32) < self.confidence_threshold {
                continue;
            }

            for region in &root_regions {
                proposals.push(
                    SemanticProposal::new(
                        region.id.clone(),
                        candidate.label.clone(),
                        candidate.confidence as f32 * 0.80,
                        self.backend_id(),
                    )
                    .with_provenance(SemanticProvenance::Structural),
                );
            }
        }
        proposals
    }
}
