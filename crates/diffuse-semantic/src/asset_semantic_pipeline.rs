//! `AssetSemanticPipeline.swift` — semantic annotation pipeline coordinator.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use crate::backends::semantic_analyzer_backend::SemanticAnalyzerBackend;
use crate::memory::semantic_memory_store::{SemanticMemoryError, SemanticMemoryStore};
use crate::semantic_contracts::{
    AmbiguityDecision, AmbiguityQuestion, AmbiguityQuestionCandidate, CandidateRegionSet,
    GeometrySignals, RawStructure, Region, RegionSource, SemanticConfirmation,
    SemanticConfirmationOutcome, SemanticProposal, SemanticProvenance,
};

#[derive(Clone, Debug, PartialEq)]
pub struct SemanticPipelineConfig {
    /// Confidence floor for automatic commit when a single backend agrees.
    pub auto_commit_threshold: f32,
    /// More conservative threshold when the only evidence is a vision backend.
    pub vision_only_auto_threshold: f32,
    /// Top-1 vs top-2 gap below which proposals are considered conflicting.
    pub conflict_margin: f32,
}

impl SemanticPipelineConfig {
    pub fn new(
        auto_commit_threshold: f32,
        vision_only_auto_threshold: f32,
        conflict_margin: f32,
    ) -> Self {
        SemanticPipelineConfig {
            auto_commit_threshold,
            vision_only_auto_threshold,
            conflict_margin,
        }
    }
}

impl Default for SemanticPipelineConfig {
    fn default() -> Self {
        SemanticPipelineConfig::new(0.85, 0.95, 0.15)
    }
}

/// Coordinates the full asset semantic annotation pass:
/// Structure → Geometry → Region → Backend analysis → Ambiguity scoring → Memory.
///
/// Backends are injected; the coordinator is pure data flow with no hidden state.
pub struct AssetSemanticPipeline {
    pub config: SemanticPipelineConfig,
    backends: Vec<Box<dyn SemanticAnalyzerBackend>>,
    memory: Option<Arc<dyn SemanticMemoryStore>>,
}

impl AssetSemanticPipeline {
    pub fn new(
        config: SemanticPipelineConfig,
        backends: Vec<Box<dyn SemanticAnalyzerBackend>>,
        memory: Option<Arc<dyn SemanticMemoryStore>>,
    ) -> Self {
        AssetSemanticPipeline {
            config,
            backends,
            memory,
        }
    }

    pub fn with_backends(backends: Vec<Box<dyn SemanticAnalyzerBackend>>) -> Self {
        AssetSemanticPipeline::new(SemanticPipelineConfig::default(), backends, None)
    }

    pub fn with_memory(memory: Arc<dyn SemanticMemoryStore>) -> Self {
        AssetSemanticPipeline::new(SemanticPipelineConfig::default(), Vec::new(), Some(memory))
    }

    // MARK: - Main entry point

    /// Runs the full pipeline and returns either auto-committed proposals or questions
    /// for the `MinimalConfirmationUI`.
    pub fn run(
        &self,
        raw_structure: &RawStructure,
        signals: &GeometrySignals,
    ) -> AmbiguityDecision {
        let region_set = Self::build_regions(raw_structure, signals);
        let proposals = self.collect_proposals(&region_set, raw_structure, signals);
        self.score(&proposals)
    }

    /// Applies user confirmations from the UI: records accepted labels in memory
    /// and returns the final committed proposals ready to write to the `inferred` World layer.
    pub fn apply(
        &self,
        confirmations: &[SemanticConfirmation],
        regions: &CandidateRegionSet,
        pending_proposals: &[SemanticProposal],
    ) -> Result<Vec<SemanticProposal>, SemanticMemoryError> {
        let mut committed = Vec::new();
        let mut by_region: BTreeMap<&str, Vec<&SemanticProposal>> = BTreeMap::new();
        for proposal in pending_proposals {
            by_region
                .entry(proposal.region_id.as_str())
                .or_default()
                .push(proposal);
        }

        for confirmation in confirmations {
            if !by_region.contains_key(confirmation.region_id.as_str()) {
                continue;
            }
            let Some(region) = regions
                .regions
                .iter()
                .find(|region| region.id == confirmation.region_id)
            else {
                continue;
            };

            match &confirmation.outcome {
                SemanticConfirmationOutcome::Accepted(label) => {
                    self.record(region, confirmation)?;
                    committed.push(
                        SemanticProposal::new(
                            confirmation.region_id.clone(),
                            label.clone(),
                            1.0,
                            "user_confirmed",
                        )
                        .with_provenance(SemanticProvenance::Confirmed),
                    );
                }
                SemanticConfirmationOutcome::Renamed(new_label) => {
                    let accepted = SemanticConfirmation::new(
                        confirmation.region_id.clone(),
                        SemanticConfirmationOutcome::Accepted(new_label.clone()),
                        confirmation.confirmed_by.clone(),
                    );
                    self.record(region, &accepted)?;
                    committed.push(
                        SemanticProposal::new(
                            confirmation.region_id.clone(),
                            new_label.clone(),
                            1.0,
                            "user_confirmed",
                        )
                        .with_provenance(SemanticProvenance::Confirmed),
                    );
                }
                SemanticConfirmationOutcome::Rejected | SemanticConfirmationOutcome::Deferred => {}
            }
        }
        Ok(committed)
    }

    // MARK: - Private

    fn record(
        &self,
        region: &Region,
        confirmation: &SemanticConfirmation,
    ) -> Result<(), SemanticMemoryError> {
        match &self.memory {
            Some(memory) => {
                memory.record(&confirmation.region_id, &region.fingerprint, confirmation)
            }
            None => Ok(()),
        }
    }

    fn build_regions(
        raw_structure: &RawStructure,
        signals: &GeometrySignals,
    ) -> CandidateRegionSet {
        let mut regions: Vec<Region> = raw_structure
            .nodes
            .iter()
            .map(|node| Region::new(format!("region:{}", node.id), RegionSource::Structural))
            .collect();

        // Geometric regions from connected components not covered by structural nodes.
        let structural_mesh_ids: BTreeSet<&str> = raw_structure
            .meshes
            .iter()
            .map(|mesh| mesh.id.as_str())
            .collect();
        for component in &signals.connected_components {
            if !structural_mesh_ids.contains(component.mesh_id.as_str()) {
                regions.push(Region::new(
                    format!("region:cc:{}", component.id),
                    RegionSource::Geometric,
                ));
            }
        }

        CandidateRegionSet::with_regions(raw_structure.asset_uri.clone(), regions)
    }

    fn collect_proposals(
        &self,
        region_set: &CandidateRegionSet,
        raw_structure: &RawStructure,
        signals: &GeometrySignals,
    ) -> Vec<SemanticProposal> {
        std::thread::scope(|scope| {
            let mut handles = Vec::with_capacity(self.backends.len());
            for backend in &self.backends {
                handles.push(scope.spawn(|| backend.analyze(region_set, raw_structure, signals)));
            }
            let mut all = Vec::new();
            for handle in handles {
                match handle.join() {
                    Ok(batch) => all.extend(batch),
                    Err(panic) => std::panic::resume_unwind(panic),
                }
            }
            all
        })
    }

    fn score(&self, proposals: &[SemanticProposal]) -> AmbiguityDecision {
        let mut auto_commit = Vec::new();
        let mut questions = Vec::new();

        let mut by_region: BTreeMap<&str, Vec<&SemanticProposal>> = BTreeMap::new();
        for proposal in proposals {
            by_region
                .entry(proposal.region_id.as_str())
                .or_default()
                .push(proposal);
        }

        for (region_id, region_proposals) in &by_region {
            let mut sorted = region_proposals.clone();
            sorted.sort_by(|a, b| {
                b.confidence
                    .partial_cmp(&a.confidence)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            let Some(top) = sorted.first() else {
                continue;
            };

            let threshold = if top.source == "vision" {
                self.config.vision_only_auto_threshold
            } else {
                self.config.auto_commit_threshold
            };
            let has_conflict = sorted.len() > 1
                && (sorted[0].confidence - sorted[1].confidence) < self.config.conflict_margin;

            if !has_conflict && top.confidence >= threshold {
                auto_commit.push((*top).clone());
            } else {
                questions.push(
                    AmbiguityQuestion::new(
                        *region_id,
                        sorted
                            .iter()
                            .map(|proposal| {
                                AmbiguityQuestionCandidate::new(
                                    proposal.label.clone(),
                                    proposal.confidence,
                                    proposal.source.clone(),
                                )
                            })
                            .collect(),
                    )
                    .with_suggested_default(top.label.clone()),
                );
            }
        }

        if questions.is_empty() {
            AmbiguityDecision::AutoCommit(auto_commit)
        } else {
            AmbiguityDecision::NeedsConfirmation(questions)
        }
    }
}
