import Foundation

// MARK: - Model metrics record

/// Performance snapshot recorded after evaluating a model on a held-out dataset.
/// All values are mandatory to consider a model for default-backend status.
public struct ModelMetricsRecord: Codable, Sendable, Equatable {
    public var modelID: String
    public var task: PerceptionTask
    public var dataset: String
    public var evaluatorVersion: String
    public var evaluatedAt: Date

    // Accuracy metrics — which field is used depends on `task`.
    /// mAP@IoU=0.50 for object detection and instance segmentation.
    public var mapAt50: Double?
    /// Top-K classification accuracy (K=1 unless noted).
    public var topKAccuracy: Double?
    /// IoU-weighted mean for segmentation masks (semantic segmentation).
    public var meanIoU: Double?

    // Latency metrics (on the reference hardware documented in `evaluatorVersion`).
    public var meanLatencyMs: Double
    public var p95LatencyMs: Double

    public init(modelID: String,
                task: PerceptionTask,
                dataset: String,
                evaluatorVersion: String,
                evaluatedAt: Date = Date(),
                mapAt50: Double? = nil,
                topKAccuracy: Double? = nil,
                meanIoU: Double? = nil,
                meanLatencyMs: Double,
                p95LatencyMs: Double) {
        self.modelID = modelID
        self.task = task
        self.dataset = dataset
        self.evaluatorVersion = evaluatorVersion
        self.evaluatedAt = evaluatedAt
        self.mapAt50 = mapAt50
        self.topKAccuracy = topKAccuracy
        self.meanIoU = meanIoU
        self.meanLatencyMs = meanLatencyMs
        self.p95LatencyMs = p95LatencyMs
    }
}

// MARK: - Evaluation gate

public enum EvaluationGateDecision: Sendable, Equatable, CustomStringConvertible {
    case approved
    case notEvaluated
    case rejectedAccuracy(actual: Double, required: Double)
    case rejectedLatency(p95Ms: Double, maxMs: Double)

    public var description: String {
        switch self {
        case .approved:
            return "approved"
        case .notEvaluated:
            return "not evaluated — no metrics record available"
        case let .rejectedAccuracy(actual, required):
            return "accuracy \(String(format: "%.3f", actual)) < required \(String(format: "%.3f", required))"
        case let .rejectedLatency(p95Ms, maxMs):
            return "p95 latency \(Int(p95Ms))ms exceeds limit \(Int(maxMs))ms"
        }
    }
}

/// Prevents a model from becoming the default backend until it passes minimum
/// accuracy and latency thresholds. Thresholds are task-specific and can be
/// overridden per project via `ProjectDocument` settings.
public struct EvaluationGate: Sendable {
    /// Minimum mAP@IoU=0.50 for detection/segmentation tasks.
    public var requiredMapAt50: Double
    /// Minimum top-K accuracy for classification tasks.
    public var requiredTopKAccuracy: Double
    /// Minimum mean IoU for semantic segmentation.
    public var requiredMeanIoU: Double
    /// Hard ceiling on p95 latency regardless of task.
    public var maxP95LatencyMs: Double

    public static let `default` = EvaluationGate(
        requiredMapAt50: 0.40,
        requiredTopKAccuracy: 0.70,
        requiredMeanIoU: 0.40,
        maxP95LatencyMs: 1_000
    )

    public init(requiredMapAt50: Double,
                requiredTopKAccuracy: Double,
                requiredMeanIoU: Double,
                maxP95LatencyMs: Double) {
        self.requiredMapAt50 = requiredMapAt50
        self.requiredTopKAccuracy = requiredTopKAccuracy
        self.requiredMeanIoU = requiredMeanIoU
        self.maxP95LatencyMs = maxP95LatencyMs
    }

    /// Evaluates a metrics record against the gate thresholds.
    public func evaluate(_ metrics: ModelMetricsRecord) -> EvaluationGateDecision {
        // Check accuracy first, then latency.
        switch metrics.task {
        case .objectDetection, .instanceSegmentation:
            guard let map = metrics.mapAt50 else { return .notEvaluated }
            if map < requiredMapAt50 {
                return .rejectedAccuracy(actual: map, required: requiredMapAt50)
            }

        case .classification:
            guard let acc = metrics.topKAccuracy else { return .notEvaluated }
            if acc < requiredTopKAccuracy {
                return .rejectedAccuracy(actual: acc, required: requiredTopKAccuracy)
            }

        case .semanticSegmentation:
            guard let iou = metrics.meanIoU else { return .notEvaluated }
            if iou < requiredMeanIoU {
                return .rejectedAccuracy(actual: iou, required: requiredMeanIoU)
            }

        case .depthEstimation, .imageEmbedding, .textImageGrounding:
            // No accuracy gate defined yet; gate on latency only.
            break
        }

        if metrics.p95LatencyMs > maxP95LatencyMs {
            return .rejectedLatency(p95Ms: metrics.p95LatencyMs, maxMs: maxP95LatencyMs)
        }

        return .approved
    }
}
