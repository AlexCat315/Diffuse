import Foundation
import IntentRuntime

public struct InferredWrite: Codable, Sendable, Equatable {
    public var property: String
    public var value: WorldPropertyValue
    public var confidence: Double
    public var source: String

    public init(property: String,
                value: WorldPropertyValue,
                confidence: Double,
                source: String) {
        self.property = property
        self.value = value
        self.confidence = confidence
        self.source = source
    }
}

public struct InferredWriteSet: Codable, Sendable, Equatable {
    public var targetRef: String
    public var writes: [InferredWrite]

    public init(targetRef: String, writes: [InferredWrite]) {
        self.targetRef = targetRef
        self.writes = writes
    }
}

public struct PerceptionWorldEventMapper: Sendable {
    public init() {}

    public func makeWriteSet(from result: PerceptionResult, targetRef: String) -> InferredWriteSet {
        var writes: [InferredWrite] = []
        let source = "perception:\(result.modelID)"

        for observation in result.observations {
            switch observation {
            case let .classification(obs):
                if let top = obs.semanticCandidates.first {
                    writes.append(InferredWrite(property: top.kind,
                                                value: .string(top.label),
                                                confidence: top.confidence,
                                                source: source))
                }

            case let .objectDetection(obs):
                if let top = obs.semanticCandidates.first {
                    writes.append(InferredWrite(property: top.kind,
                                                value: .string(top.label),
                                                confidence: top.confidence,
                                                source: source))
                }
                if let bbox = obs.bbox2D {
                    writes.append(InferredWrite(property: "perception.bbox2d",
                                                value: .vec4(bbox.x, bbox.y, bbox.width, bbox.height),
                                                confidence: obs.confidence,
                                                source: source))
                }

            case let .imageEmbedding(obs):
                // Embedding vectors are prompt_forbidden — only record that one exists
                writes.append(InferredWrite(property: "perception.embedding_available",
                                            value: .string(obs.vectorSpaceID),
                                            confidence: 1.0,
                                            source: source))
            }
        }

        let labels = result.observations.compactMap(\.primaryCandidate?.label)
        if labels.count > 1 {
            writes.append(InferredWrite(property: "perception.summary",
                                        value: .string(labels.joined(separator: ", ")),
                                        confidence: 1.0,
                                        source: source))
        } else if labels.count == 1, let first = labels.first {
            writes.append(InferredWrite(property: "perception.summary",
                                        value: .string(first),
                                        confidence: writes.first?.confidence ?? 1.0,
                                        source: source))
        }

        return InferredWriteSet(targetRef: targetRef, writes: writes)
    }

    public func makeWorldEvents(from result: PerceptionResult, targetRef: String) -> [WorldEvent] {
        makeWriteSet(from: result, targetRef: targetRef).writes.map { write in
            .entityInferredUpdated(ref: targetRef,
                                   property: write.property,
                                   value: write.value,
                                   confidence: write.confidence,
                                   source: write.source)
        }
    }
}
