//! `EvaluationGate.swift` — accuracy and latency thresholds for default-backend status.

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::core::perception_contracts::PerceptionTask;

/// Swift's `Date` epoch: 2001-01-01T00:00:00Z in Unix seconds.
pub const SWIFT_DATE_REFERENCE_UNIX_SECONDS: i64 = 978_307_200;

/// Swift `Date` encodes as seconds since 2001-01-01 in UTC.
pub fn date_to_swift_seconds(date: std::time::SystemTime) -> f64 {
    match date.duration_since(std::time::UNIX_EPOCH) {
        Ok(duration) => duration.as_secs_f64() - SWIFT_DATE_REFERENCE_UNIX_SECONDS as f64,
        Err(_) => 0.0,
    }
}

/// A timestamp carried in Swift's `Date` encoding.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SwiftDate(pub f64);

impl SwiftDate {
    pub fn now() -> Self {
        SwiftDate(date_to_swift_seconds(std::time::SystemTime::now()))
    }
}

impl Serialize for SwiftDate {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        diffuse_kernel::codable::serialize_double(&self.0, serializer)
    }
}

impl<'de> Deserialize<'de> for SwiftDate {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<SwiftDate, D::Error> {
        f64::deserialize(deserializer).map(SwiftDate)
    }
}

/// Performance snapshot recorded after evaluating a model on a held-out dataset.
///
/// Every value is mandatory to consider a model for default-backend status.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelMetricsRecord {
    pub model_id: String,
    pub task: PerceptionTask,
    pub dataset: String,
    pub evaluator_version: String,
    pub evaluated_at: SwiftDate,

    /// mAP@IoU=0.50 for object detection and instance segmentation.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "diffuse_kernel::codable::serialize_optional_double"
    )]
    pub map_at_50: Option<f64>,
    /// Top-K classification accuracy (K=1 unless noted).
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "diffuse_kernel::codable::serialize_optional_double"
    )]
    pub top_k_accuracy: Option<f64>,
    /// IoU-weighted mean for segmentation masks (semantic segmentation).
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        serialize_with = "diffuse_kernel::codable::serialize_optional_double"
    )]
    pub mean_iou: Option<f64>,

    /// Latency on the reference hardware documented in `evaluator_version`.
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub mean_latency_ms: f64,
    #[serde(serialize_with = "diffuse_kernel::codable::serialize_double")]
    pub p95_latency_ms: f64,
}

impl ModelMetricsRecord {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        model_id: impl Into<String>,
        task: PerceptionTask,
        dataset: impl Into<String>,
        evaluator_version: impl Into<String>,
        evaluated_at: SwiftDate,
        map_at_50: Option<f64>,
        top_k_accuracy: Option<f64>,
        mean_iou: Option<f64>,
        mean_latency_ms: f64,
        p95_latency_ms: f64,
    ) -> Self {
        ModelMetricsRecord {
            model_id: model_id.into(),
            task,
            dataset: dataset.into(),
            evaluator_version: evaluator_version.into(),
            evaluated_at,
            map_at_50,
            top_k_accuracy,
            mean_iou,
            mean_latency_ms,
            p95_latency_ms,
        }
    }

    /// Swift's member-wise defaults (`evaluatedAt = Date()`, metric fields `nil`).
    pub fn with_defaults(
        model_id: impl Into<String>,
        task: PerceptionTask,
        dataset: impl Into<String>,
        evaluator_version: impl Into<String>,
        mean_latency_ms: f64,
        p95_latency_ms: f64,
    ) -> Self {
        Self::new(
            model_id,
            task,
            dataset,
            evaluator_version,
            SwiftDate::now(),
            None,
            None,
            None,
            mean_latency_ms,
            p95_latency_ms,
        )
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum EvaluationGateDecision {
    Approved,
    NotEvaluated,
    RejectedAccuracy { actual: f64, required: f64 },
    RejectedLatency { p95_ms: f64, max_ms: f64 },
}

impl std::fmt::Display for EvaluationGateDecision {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EvaluationGateDecision::Approved => formatter.write_str("approved"),
            EvaluationGateDecision::NotEvaluated => {
                formatter.write_str("not evaluated — no metrics record available")
            }
            EvaluationGateDecision::RejectedAccuracy { actual, required } => {
                write!(formatter, "accuracy {actual:.3} < required {required:.3}")
            }
            EvaluationGateDecision::RejectedLatency { p95_ms, max_ms } => write!(
                formatter,
                "p95 latency {}ms exceeds limit {}ms",
                *p95_ms as i64, *max_ms as i64
            ),
        }
    }
}

/// Prevents a model from becoming the default backend until it passes minimum
/// accuracy and latency thresholds.
#[derive(Clone, Debug, PartialEq)]
pub struct EvaluationGate {
    /// Minimum mAP@IoU=0.50 for detection/segmentation tasks.
    pub required_map_at_50: f64,
    /// Minimum top-K accuracy for classification tasks.
    pub required_top_k_accuracy: f64,
    /// Minimum mean IoU for semantic segmentation.
    pub required_mean_iou: f64,
    /// Hard ceiling on p95 latency regardless of task.
    pub max_p95_latency_ms: f64,
}

impl EvaluationGate {
    pub fn new(
        required_map_at_50: f64,
        required_top_k_accuracy: f64,
        required_mean_iou: f64,
        max_p95_latency_ms: f64,
    ) -> Self {
        EvaluationGate {
            required_map_at_50,
            required_top_k_accuracy,
            required_mean_iou,
            max_p95_latency_ms,
        }
    }

    /// Evaluates a metrics record against the gate thresholds.
    pub fn evaluate(&self, metrics: &ModelMetricsRecord) -> EvaluationGateDecision {
        // Accuracy first, then latency.
        match metrics.task {
            PerceptionTask::ObjectDetection | PerceptionTask::InstanceSegmentation => {
                let Some(map) = metrics.map_at_50 else {
                    return EvaluationGateDecision::NotEvaluated;
                };
                if map < self.required_map_at_50 {
                    return EvaluationGateDecision::RejectedAccuracy {
                        actual: map,
                        required: self.required_map_at_50,
                    };
                }
            }
            PerceptionTask::Classification => {
                let Some(accuracy) = metrics.top_k_accuracy else {
                    return EvaluationGateDecision::NotEvaluated;
                };
                if accuracy < self.required_top_k_accuracy {
                    return EvaluationGateDecision::RejectedAccuracy {
                        actual: accuracy,
                        required: self.required_top_k_accuracy,
                    };
                }
            }
            PerceptionTask::SemanticSegmentation => {
                let Some(iou) = metrics.mean_iou else {
                    return EvaluationGateDecision::NotEvaluated;
                };
                if iou < self.required_mean_iou {
                    return EvaluationGateDecision::RejectedAccuracy {
                        actual: iou,
                        required: self.required_mean_iou,
                    };
                }
            }
            PerceptionTask::DepthEstimation
            | PerceptionTask::ImageEmbedding
            | PerceptionTask::TextImageGrounding => {
                // No accuracy gate defined yet; gate on latency only.
            }
        }

        if metrics.p95_latency_ms > self.max_p95_latency_ms {
            return EvaluationGateDecision::RejectedLatency {
                p95_ms: metrics.p95_latency_ms,
                max_ms: self.max_p95_latency_ms,
            };
        }

        EvaluationGateDecision::Approved
    }
}

impl Default for EvaluationGate {
    fn default() -> Self {
        EvaluationGate::new(0.40, 0.70, 0.40, 1_000.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metrics_record_keeps_swift_member_names_and_date_epoch() {
        let metrics = ModelMetricsRecord::new(
            "rt_detr_v2",
            PerceptionTask::ObjectDetection,
            "coco_val2017",
            "eval_v1",
            SwiftDate(0.0),
            Some(0.55),
            None,
            None,
            45.0,
            120.0,
        );
        let value = serde_json::to_value(&metrics).expect("encode metrics");
        assert_eq!(value["modelId"], "rt_detr_v2");
        assert_eq!(value["evaluatorVersion"], "eval_v1");
        assert_eq!(value["evaluatedAt"], 0);
        assert_eq!(value["mapAt50"], 0.55);
        assert_eq!(value["p95LatencyMs"], 120);
        assert!(value.get("topKAccuracy").is_none());
    }
}
