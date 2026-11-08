//! `GeometryBackend.swift` — shape-feature category inference.

use std::sync::Arc;

use crate::asset_semantic_pipeline::{AssetSemanticPipeline, SemanticPipelineConfig};
use crate::backends::semantic_analyzer_backend::{
    MetadataBackend, NameHeuristicBackend, RigBackend, SemanticAnalyzerBackend,
};
use crate::backends::vision_backend::VisionBackend;
use crate::memory::semantic_memory_store::SemanticMemoryStore;
use crate::semantic_contracts::{
    CandidateRegionSet, GeometrySignals, RawStructure, RegionSource, SemanticProposal,
    SemanticProvenance,
};

/// Infers semantic category from shape features in `GeometrySignals`.
///
/// Proposals target the root structural region (whole asset) or individual connected
/// components. Confidence is intentionally modest (0.50–0.72) because geometric
/// heuristics are weaker than naming or metadata evidence — the arbitration layer
/// in `AssetSemanticPipeline` handles conflicts with other backends.
pub struct GeometryBackend;

impl GeometryBackend {
    pub fn new() -> Self {
        GeometryBackend
    }

    fn aabb_aspect_ratio_category(signals: &GeometrySignals) -> AABBCategory {
        if signals.connected_components.is_empty() {
            return AABBCategory::Medium;
        }

        let mut min_x = f32::MAX;
        let mut max_x = -f32::MAX;
        let mut min_y = f32::MAX;
        let mut max_y = -f32::MAX;
        let mut min_z = f32::MAX;
        let mut max_z = -f32::MAX;

        for cc in &signals.connected_components {
            min_x = min_x.min(cc.bounds.min.0);
            max_x = max_x.max(cc.bounds.max.0);
            min_y = min_y.min(cc.bounds.min.1);
            max_y = max_y.max(cc.bounds.max.1);
            min_z = min_z.min(cc.bounds.min.2);
            max_z = max_z.max(cc.bounds.max.2);
        }

        let height = max_y - min_y;
        let width = (max_x - min_x).max(max_z - min_z);
        if width <= 0.001 {
            return AABBCategory::Medium;
        }
        let ar = height / width;

        if ar >= 3.0 {
            AABBCategory::Tall
        } else if ar < 0.20 {
            AABBCategory::Flat
        } else if (0.70..=1.40).contains(&ar) {
            AABBCategory::Cubic
        } else {
            AABBCategory::Medium
        }
    }
}

impl Default for GeometryBackend {
    fn default() -> Self {
        GeometryBackend::new()
    }
}

impl SemanticAnalyzerBackend for GeometryBackend {
    fn backend_id(&self) -> &'static str {
        "geometry"
    }

    fn analyze(
        &self,
        regions: &CandidateRegionSet,
        _raw_structure: &RawStructure,
        signals: &GeometrySignals,
    ) -> Vec<SemanticProposal> {
        if regions.regions.is_empty() {
            return Vec::new();
        }
        let mut proposals = Vec::new();

        // --- Root-level asset category ---
        let Some(root_region) = regions.regions.iter().find(|region| {
            region.parent_region_id.is_none() && region.source == RegionSource::Structural
        }) else {
            return Vec::new();
        };

        let has_strong_symmetry = signals
            .symmetry_axes
            .iter()
            .any(|axis| axis.confidence > 0.60);
        let protrusion_count = signals.protrusions.len();
        let has_support_plane = !signals.support_planes.is_empty();
        let aabb_category = Self::aabb_aspect_ratio_category(signals);

        // Character detection: bilateral symmetry + limb-like protrusions
        if has_strong_symmetry && protrusion_count >= 4 {
            proposals.push(
                SemanticProposal::new(root_region.id.clone(), "character", 0.65, self.backend_id())
                    .with_provenance(SemanticProvenance::Geometric),
            );
        } else if has_strong_symmetry && protrusion_count == 2 {
            proposals.push(
                SemanticProposal::new(
                    root_region.id.clone(),
                    "bipedal_prop",
                    0.55,
                    self.backend_id(),
                )
                .with_provenance(SemanticProvenance::Geometric),
            );
        }

        // Furniture detection: flat support plane + moderate height
        if has_support_plane && aabb_category == AABBCategory::Medium {
            proposals.push(
                SemanticProposal::new(root_region.id.clone(), "furniture", 0.60, self.backend_id())
                    .with_provenance(SemanticProvenance::Geometric),
            );
        }

        // Tall narrow asset: column, tree, or upright prop
        if aabb_category == AABBCategory::Tall {
            proposals.push(
                SemanticProposal::new(
                    root_region.id.clone(),
                    "upright_prop",
                    0.55,
                    self.backend_id(),
                )
                .with_provenance(SemanticProvenance::Geometric),
            );
        }

        // Very flat asset: decal, rug, floor panel
        if aabb_category == AABBCategory::Flat {
            proposals.push(
                SemanticProposal::new(
                    root_region.id.clone(),
                    "flat_surface",
                    0.58,
                    self.backend_id(),
                )
                .with_provenance(SemanticProvenance::Geometric),
            );
        }

        // Near-cubic compact prop with no distinguishing features
        if aabb_category == AABBCategory::Cubic && !has_strong_symmetry && !has_support_plane {
            proposals.push(
                SemanticProposal::new(root_region.id.clone(), "prop", 0.50, self.backend_id())
                    .with_provenance(SemanticProvenance::Geometric),
            );
        }

        // --- Per-component protrusion labelling ---
        if protrusion_count > 0 {
            for (i, protrusion) in signals.protrusions.iter().enumerate() {
                let aspect_ratio = protrusion.length / protrusion.base_radius.max(0.001);
                let label = if aspect_ratio > 4.0 {
                    "limb"
                } else if aspect_ratio > 2.0 {
                    "appendage"
                } else {
                    "protrusion"
                };
                proposals.push(
                    SemanticProposal::new(
                        format!("region:protrusion:{}", protrusion.id),
                        label,
                        0.60 - i as f32 * 0.02,
                        self.backend_id(),
                    )
                    .with_provenance(SemanticProvenance::Geometric),
                );
            }
        }

        proposals
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AABBCategory {
    Tall,
    Flat,
    Cubic,
    Medium,
}

// MARK: - Pipeline standard configuration

impl AssetSemanticPipeline {
    /// Returns a pipeline configured with all built-in backends: name heuristic,
    /// rig, metadata, geometry, and vision (Apple Vision classifier).
    /// Pass `memory` to enable cross-session recall.
    pub fn standard(memory: Option<Arc<dyn SemanticMemoryStore>>) -> AssetSemanticPipeline {
        AssetSemanticPipeline::new(
            SemanticPipelineConfig::default(),
            vec![
                Box::new(NameHeuristicBackend::new()),
                Box::new(RigBackend::new()),
                Box::new(MetadataBackend::default()),
                Box::new(GeometryBackend::new()),
                Box::new(VisionBackend::with_defaults()),
            ],
            memory,
        )
    }
}
