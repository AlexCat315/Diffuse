//! `PerceptionWorldEventMapper.swift` — perception results to inferred world events.

use diffuse_intent::transactions::world_event::{WorldEvent, WorldPropertyValue};
use diffuse_kernel::codable::serialize_double;
use serde::{Deserialize, Serialize};

use crate::core::perception_contracts::{PerceptionObservation, PerceptionResult};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InferredWrite {
    pub property: String,
    pub value: WorldPropertyValue,
    #[serde(serialize_with = "serialize_double")]
    pub confidence: f64,
    pub source: String,
}

impl InferredWrite {
    pub fn new(
        property: impl Into<String>,
        value: WorldPropertyValue,
        confidence: f64,
        source: impl Into<String>,
    ) -> Self {
        InferredWrite {
            property: property.into(),
            value,
            confidence,
            source: source.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InferredWriteSet {
    pub target_ref: String,
    pub writes: Vec<InferredWrite>,
}

impl InferredWriteSet {
    pub fn new(target_ref: impl Into<String>, writes: Vec<InferredWrite>) -> Self {
        InferredWriteSet {
            target_ref: target_ref.into(),
            writes,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct PerceptionWorldEventMapper;

impl PerceptionWorldEventMapper {
    pub fn new() -> Self {
        PerceptionWorldEventMapper
    }

    pub fn make_write_set(&self, result: &PerceptionResult, target_ref: &str) -> InferredWriteSet {
        let mut writes: Vec<InferredWrite> = Vec::new();
        let source = format!("perception:{}", result.model_id);

        for observation in &result.observations {
            match observation {
                PerceptionObservation::Classification(observation) => {
                    if let Some(top) = observation.semantic_candidates.first() {
                        writes.push(InferredWrite::new(
                            top.kind.clone(),
                            WorldPropertyValue::String(top.label.clone()),
                            top.confidence,
                            source.clone(),
                        ));
                    }
                }
                PerceptionObservation::ObjectDetection(observation) => {
                    if let Some(top) = observation.semantic_candidates.first() {
                        writes.push(InferredWrite::new(
                            top.kind.clone(),
                            WorldPropertyValue::String(top.label.clone()),
                            top.confidence,
                            source.clone(),
                        ));
                    }
                    if let Some(bbox) = observation.bbox2_d {
                        writes.push(InferredWrite::new(
                            "perception.bbox2d",
                            WorldPropertyValue::Vec4(bbox.x, bbox.y, bbox.width, bbox.height),
                            observation.confidence,
                            source.clone(),
                        ));
                    }
                }
                PerceptionObservation::ImageEmbedding(observation) => {
                    // Embedding vectors are prompt_forbidden — only record that one exists.
                    writes.push(InferredWrite::new(
                        "perception.embedding_available",
                        WorldPropertyValue::String(observation.vector_space_id.clone()),
                        1.0,
                        source.clone(),
                    ));
                }
            }
        }

        let labels: Vec<&str> = result
            .observations
            .iter()
            .filter_map(|observation| {
                observation
                    .primary_candidate()
                    .map(|top| top.label.as_str())
            })
            .collect();
        if labels.len() > 1 {
            writes.push(InferredWrite::new(
                "perception.summary",
                WorldPropertyValue::String(labels.join(", ")),
                1.0,
                source.clone(),
            ));
        } else if labels.len() == 1 {
            let first = labels[0];
            let confidence = writes.first().map(|write| write.confidence).unwrap_or(1.0);
            writes.push(InferredWrite::new(
                "perception.summary",
                WorldPropertyValue::String(first.to_string()),
                confidence,
                source.clone(),
            ));
        }

        InferredWriteSet::new(target_ref, writes)
    }

    pub fn make_world_events(
        &self,
        result: &PerceptionResult,
        target_ref: &str,
    ) -> Vec<WorldEvent> {
        self.make_write_set(result, target_ref)
            .writes
            .into_iter()
            .map(|write| WorldEvent::EntityInferredUpdated {
                ref_: target_ref.to_string(),
                property: write.property,
                value: write.value,
                confidence: write.confidence,
                source: Some(write.source),
            })
            .collect()
    }
}
