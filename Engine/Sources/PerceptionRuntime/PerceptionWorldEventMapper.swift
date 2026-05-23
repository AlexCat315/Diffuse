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
        if let top = result.observations.compactMap(\.primaryCandidate)
            .sorted(by: { $0.confidence > $1.confidence })
            .first {
            writes.append(InferredWrite(property: top.kind,
                                        value: .string(top.label),
                                        confidence: top.confidence,
                                        source: "perception:\(result.modelID)"))
        }

        let labels = result.observations.compactMap { observation -> String? in
            observation.primaryCandidate?.label
        }
        if !labels.isEmpty {
            writes.append(InferredWrite(property: "perception.summary",
                                        value: .string(labels.joined(separator: ", ")),
                                        confidence: labels.count == 1 ? (writes.first?.confidence ?? 1.0) : 1.0,
                                        source: "perception:\(result.modelID)"))
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
