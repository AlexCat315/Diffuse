import Foundation

public struct RegisteredStatePayload: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var valueType: String
    public var scopeID: String?
    public init(id: String, name: String, valueType: String, scopeID: String? = nil) {
        self.id = id; self.name = name; self.valueType = valueType; self.scopeID = scopeID
    }
}
public struct StateWatchPayload: Codable, Sendable {
    public var ids: [String]
    public init(ids: [String]) { self.ids = ids }
    public var isValid: Bool {
        ids.count <= 128 && Set(ids).count == ids.count && ids.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
    }
}
public struct ObservedStatePayload: Codable, Equatable, Sendable {
    public var id: String
    public var summary: String
    public var truncated: Bool
    public init(id: String, summary: String, truncated: Bool) {
        self.id = id; self.summary = summary; self.truncated = truncated
    }
}
public struct StateObservationPayload: Codable, Equatable, Sendable {
    public var registered: [RegisteredStatePayload]
    public var values: [ObservedStatePayload]
    public init(registered: [RegisteredStatePayload], values: [ObservedStatePayload]) {
        self.registered = registered; self.values = values
    }
}
public struct TimelineEventPayload: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var phase: String
    public var name: String
    public var scopeID: String?
    public var startMs: Double
    public var durationMs: Double
    public var reasons: [TimelineReasonPayload]
    public init(sequence: UInt64, phase: String, name: String, scopeID: String?, startMs: Double,
                durationMs: Double, reasons: [TimelineReasonPayload] = []) {
        self.sequence = sequence; self.phase = phase; self.name = name; self.scopeID = scopeID
        self.startMs = startMs; self.durationMs = durationMs; self.reasons = reasons
    }
}
public struct TimelineReasonPayload: Codable, Equatable, Sendable {
    public var kind: String
    public var detail: String?
    public init(kind: String, detail: String?) { self.kind = kind; self.detail = detail }
}
public struct TimelineSnapshotPayload: Codable, Sendable {
    public var events: [TimelineEventPayload]
    public var dropped: Int
    public init(events: [TimelineEventPayload], dropped: Int = 0) { self.events = events; self.dropped = dropped }
}
