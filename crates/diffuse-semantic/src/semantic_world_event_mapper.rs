//! `SemanticWorldEventMapper.swift` — committed proposals to inferred World events.

use diffuse_intent::transactions::world_event::{WorldEvent, WorldPropertyValue};

use crate::semantic_contracts::{SemanticProposal, SemanticProvenance};

/// Maps committed `SemanticProposal`s to `WorldEvent`s for injection into the World inferred layer.
///
/// Usage:
/// ```text
/// let events = SemanticWorldEventMapper::new().make_world_events(&proposals, "scene:42");
/// session.observe(&events);
/// ```
#[derive(Default)]
pub struct SemanticWorldEventMapper;

impl SemanticWorldEventMapper {
    pub fn new() -> Self {
        SemanticWorldEventMapper
    }

    /// Converts a list of committed proposals into `entityInferredUpdated` WorldEvents.
    /// The `target_ref` is the entity reference in the scene (e.g. `"scene:42"`).
    pub fn make_world_events(
        &self,
        proposals: &[SemanticProposal],
        target_ref: &str,
    ) -> Vec<WorldEvent> {
        if proposals.is_empty() {
            return Vec::new();
        }
        let mut events = Vec::new();

        // semanticRole: highest-confidence proposal, biased toward confirmed/metadata sources.
        let mut ranked: Vec<&SemanticProposal> = proposals.iter().collect();
        ranked.sort_by(|a, b| {
            let a_confirmed = a.provenance == SemanticProvenance::Confirmed;
            let b_confirmed = b.provenance == SemanticProvenance::Confirmed;
            b_confirmed
                .cmp(&a_confirmed)
                .then_with(|| (b.source == "metadata").cmp(&(a.source == "metadata")))
                .then_with(|| {
                    b.confidence
                        .partial_cmp(&a.confidence)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
        });
        if let Some(top) = ranked.first() {
            events.push(WorldEvent::EntityInferredUpdated {
                ref_: target_ref.to_string(),
                property: "semanticRole".to_string(),
                value: WorldPropertyValue::String(top.label.clone()),
                confidence: f64::from(top.confidence),
                source: Some(format!("semantic:{}", top.source)),
            });
        }

        // semanticParts: all structural/geometric region labels joined as a summary.
        let part_proposals: Vec<&SemanticProposal> = proposals
            .iter()
            .filter(|proposal| {
                !proposal.region_id.contains(":bone:") && !proposal.region_id.contains(":mat:")
            })
            .collect();
        let mut unique_part_labels: Vec<&str> = part_proposals
            .iter()
            .map(|proposal| proposal.label.as_str())
            .collect();
        unique_part_labels.sort_unstable();
        unique_part_labels.dedup();
        if unique_part_labels.len() > 1 {
            let avg_confidence = part_proposals
                .iter()
                .map(|proposal| proposal.confidence)
                .sum::<f32>()
                / part_proposals.len() as f32;
            events.push(WorldEvent::EntityInferredUpdated {
                ref_: target_ref.to_string(),
                property: "semanticParts".to_string(),
                value: WorldPropertyValue::String(unique_part_labels.join(", ")),
                confidence: f64::from(avg_confidence),
                source: Some("semantic:pipeline".to_string()),
            });
        }

        // rigParts: bone labels from RigBackend.
        let rig_proposals: Vec<&SemanticProposal> = proposals
            .iter()
            .filter(|proposal| proposal.source == "rig")
            .collect();
        let mut rig_labels: Vec<&str> = rig_proposals
            .iter()
            .map(|proposal| proposal.label.as_str())
            .collect();
        rig_labels.sort_unstable();
        rig_labels.dedup();
        if !rig_labels.is_empty() {
            let avg_confidence = rig_proposals
                .iter()
                .map(|proposal| proposal.confidence)
                .sum::<f32>()
                / rig_proposals.len() as f32;
            events.push(WorldEvent::EntityInferredUpdated {
                ref_: target_ref.to_string(),
                property: "rigParts".to_string(),
                value: WorldPropertyValue::String(rig_labels.join(", ")),
                confidence: f64::from(avg_confidence),
                source: Some("semantic:rig".to_string()),
            });
        }

        events
    }
}
