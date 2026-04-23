import Foundation

public struct EventDraft: Sendable, Equatable {
    public var kind: EventKindID
    public var streamID: String
    public var causalSeq: UInt64?
    public var origin: EventOrigin
    public var causationID: String?
    public var correlationID: String?
    public var provenance: EventProvenance
    public var payloadRef: EventPayloadRef
    public var schemaVersion: UInt32

    public init(kind: EventKindID,
                streamID: String,
                causalSeq: UInt64? = nil,
                origin: EventOrigin,
                causationID: String? = nil,
                correlationID: String? = nil,
                provenance: EventProvenance,
                payloadRef: EventPayloadRef,
                schemaVersion: UInt32 = 1) {
        self.kind = kind
        self.streamID = streamID
        self.causalSeq = causalSeq
        self.origin = origin
        self.causationID = causationID
        self.correlationID = correlationID
        self.provenance = provenance
        self.payloadRef = payloadRef
        self.schemaVersion = schemaVersion
    }
}

public final class OutboxRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [EventDraft] = []

    public init() {}

    public func enqueue(_ draft: EventDraft) {
        lock.lock()
        drafts.append(draft)
        lock.unlock()
    }

    public func pendingCount() -> Int {
        lock.lock()
        let count = drafts.count
        lock.unlock()
        return count
    }

    public func flush(into bus: ObservationBus) throws -> [EventEnvelope] {
        lock.lock()
        let snapshot = drafts
        lock.unlock()
        let published = try bus.publishBatch(snapshot)
        lock.lock()
        drafts.removeAll(keepingCapacity: true)
        lock.unlock()
        return published
    }
}