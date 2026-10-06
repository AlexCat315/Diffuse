import GuavaUIScene
import GuavaUIDevToolsProtocol

public extension StateRegistry {
    func observation(ids: [String]) -> StateObservationPayload {
        StateObservationPayload(registered: descriptors.map {
            RegisteredStatePayload(id: $0.id, name: $0.name, valueType: $0.valueType, scopeID: $0.scopeID)
        }, values: values(for: ids).map { ObservedStatePayload(id: $0.id, summary: $0.summary, truncated: $0.truncated) })
    }
}
public extension PerformanceTimeline {
    func snapshot(after sequence: UInt64 = 0) -> TimelineSnapshotPayload {
        TimelineSnapshotPayload(events: events(after: sequence).map { event in
            TimelineEventPayload(sequence: event.sequence, phase: event.phase, name: event.name,
                scopeID: event.scopeID, startMs: event.startMs, durationMs: event.durationMs,
                reasons: event.reasons.map { TimelineReasonPayload(kind: $0.kind, detail: $0.detail) })
        }, dropped: dropped)
    }
}
