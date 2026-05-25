import Dispatch
import Foundation

// MARK: - Snapshot resync

/// Cursor marking the position in a stream at which a snapshot was taken.
public struct StreamCursor: Sendable, Equatable {
    public var streamID: String
    public var seq: UInt64

    public init(streamID: String, seq: UInt64) {
        self.streamID = streamID
        self.seq = seq
    }
}

/// A domain store implements this protocol to support §8 resync subscribers.
/// `materializeSnapshot` must be idempotent and safe to call concurrently.
public protocol SnapshotProvider: Sendable {
    /// Capture the current domain state. Returns an opaque `snapshotID` (e.g. a UUID
    /// or file path) and the event cursor that was current when the snapshot was taken.
    func materializeSnapshot(scope: String) async throws -> (snapshotID: String, cursor: StreamCursor)
}

public enum SubscriptionDeliveryGuarantee: String, Sendable, Equatable {
    case atLeastOnce = "at_least_once"
    case bestEffort = "best_effort"
}

public enum SubscriptionAckMode: String, Sendable, Equatable {
    case auto
    case manual
}

public enum SubscriptionStartFrom: Sendable, Equatable {
    case latest
    case fromSeq(streamID: String, seq: UInt64)
    case fromSnapshot(snapshotID: String)
}

public enum SubscriptionBufferPolicy: Sendable, Equatable {
    case boundedQueue(size: Int)
    case dropOldest(size: Int)
    case dropNewest(size: Int)
    case coalesce(size: Int, keyFields: [String])
}

public indirect enum EventFilter: Sendable, Equatable {
    case all
    case kindIn([EventKindID])
    case streamIn([String])
    case originProcessIn([EventOriginProcessKind])
    case provenanceIn([EventProvenance])
    case causationIn([String])
    case and([EventFilter])
    case or([EventFilter])
    case not(EventFilter)

    func matches(_ envelope: EventEnvelope) -> Bool {
        switch self {
        case .all:
            return true
        case let .kindIn(kinds):
            return kinds.contains(envelope.kind)
        case let .streamIn(streams):
            return streams.contains(envelope.streamID)
        case let .originProcessIn(processes):
            return processes.contains(envelope.origin.process)
        case let .provenanceIn(provenances):
            return provenances.contains(envelope.provenance)
        case let .causationIn(ids):
            return envelope.causationID.map(ids.contains) ?? false
        case let .and(filters):
            return filters.allSatisfy { $0.matches(envelope) }
        case let .or(filters):
            return filters.contains { $0.matches(envelope) }
        case let .not(filter):
            return !filter.matches(envelope)
        }
    }
}

public struct SubscriptionSpec: Sendable, Equatable {
    public var id: String
    public var filter: EventFilter
    public var delivery: SubscriptionDeliveryGuarantee
    public var startFrom: SubscriptionStartFrom
    public var bufferPolicy: SubscriptionBufferPolicy
    public var ackMode: SubscriptionAckMode

    public init(id: String = UUID().uuidString,
                filter: EventFilter = .all,
                delivery: SubscriptionDeliveryGuarantee = .bestEffort,
                startFrom: SubscriptionStartFrom = .latest,
                bufferPolicy: SubscriptionBufferPolicy = .dropOldest(size: 64),
                ackMode: SubscriptionAckMode = .auto) {
        self.id = id
        self.filter = filter
        self.delivery = delivery
        self.startFrom = startFrom
        self.bufferPolicy = bufferPolicy
        self.ackMode = ackMode
    }
}

public final class ObservationSubscription: @unchecked Sendable {
    public let id: String
    public let spec: SubscriptionSpec

    private let lock = NSLock()
    private var queue: [EventEnvelope]

    fileprivate init(spec: SubscriptionSpec, initialEvents: [EventEnvelope]) {
        self.id = spec.id
        self.spec = spec
        self.queue = initialEvents
    }

    public func drain() -> [EventEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = queue
        if spec.ackMode == .auto {
            queue.removeAll(keepingCapacity: true)
        }
        return snapshot
    }

    public func ack(streamID: String, seq: UInt64) {
        lock.lock()
        queue.removeAll { $0.streamID == streamID && $0.seq <= seq }
        lock.unlock()
    }

    fileprivate func enqueue(_ envelope: EventEnvelope) {
        lock.lock()
        defer { lock.unlock() }
        switch spec.bufferPolicy {
        case let .boundedQueue(size):
            let capacity = max(1, size)
            if queue.count >= capacity {
                queue.removeFirst(queue.count - capacity + 1)
            }
            queue.append(envelope)

        case let .dropOldest(size):
            let capacity = max(1, size)
            if queue.count >= capacity {
                queue.removeFirst(queue.count - capacity + 1)
            }
            queue.append(envelope)

        case let .dropNewest(size):
            guard queue.count < max(1, size) else {
                return
            }
            queue.append(envelope)

        case let .coalesce(size, keyFields):
            let capacity = max(1, size)
            if let newKey = envelope.payloadRef.inlineRecord?.coalesceKey(for: keyFields),
               let index = queue.lastIndex(where: { existing in
                   existing.payloadRef.inlineRecord?.coalesceKey(for: keyFields) == newKey
               }) {
                queue[index] = envelope
                return
            }
            if queue.count >= capacity {
                queue.removeFirst(queue.count - capacity + 1)
            }
            queue.append(envelope)
        }
    }
}

public final class ObservationBus: @unchecked Sendable {
    public let registry: EventKindRegistry

    private let lock = NSLock()
    private let ringLimit: Int
    private var nextSeqByStream: [String: UInt64] = [:]
    private var eventsByStream: [String: [EventEnvelope]] = [:]
    private var subscriptions: [String: ObservationSubscription] = [:]
    private var snapshotProviders: [String: any SnapshotProvider] = [:]
    private var snapshotCursors: [String: StreamCursor] = [:]

    private let coldLog: ColdLog?

    public init(registry: EventKindRegistry = .default,
                coldLogDirectory: String? = nil,
                ringLimit: Int = 256) throws {
        self.registry = registry
        self.ringLimit = max(1, ringLimit)
        if let coldLogDirectory {
            self.coldLog = try ColdLog(directoryPath: coldLogDirectory)
        } else {
            self.coldLog = nil
        }
    }

    public func subscribe(spec: SubscriptionSpec) -> ObservationSubscription {
        lock.lock()
        let initialEvents = initialEventsLocked(for: spec)
        let subscription = ObservationSubscription(spec: spec, initialEvents: initialEvents)
        subscriptions[subscription.id] = subscription
        lock.unlock()
        return subscription
    }

    public func unsubscribe(_ subscriptionID: String) {
        lock.lock()
        subscriptions.removeValue(forKey: subscriptionID)
        lock.unlock()
    }

    // MARK: - Snapshot resync (§8)

    /// Register a snapshot provider for a given scope (e.g. "scene", "sequence").
    public func registerSnapshotProvider(_ provider: some SnapshotProvider, forScope scope: String) {
        lock.lock()
        snapshotProviders[scope] = provider
        lock.unlock()
    }

    /// Materialize a snapshot for `scope` and record its cursor so that subscribers
    /// can use `.fromSnapshot(snapshotID)` to receive events after the snapshot point.
    ///
    /// Typical resync pattern:
    /// ```swift
    /// let (id, cursor) = try await bus.requestSnapshot(scope: "scene")
    /// // … consume the snapshot via the provider …
    /// let sub = bus.subscribe(spec: SubscriptionSpec(startFrom: .fromSnapshot(snapshotID: id)))
    /// ```
    public func requestSnapshot(scope: String) async throws -> (snapshotID: String, cursor: StreamCursor) {
        // Read provider under lock — NSLock is not async-safe so we hold it only briefly.
        let provider = withLock { snapshotProviders[scope] }
        guard let provider else {
            throw ObservationBusError.noSnapshotProvider(scope: scope)
        }
        let (snapshotID, cursor) = try await provider.materializeSnapshot(scope: scope)
        withLock { snapshotCursors[snapshotID] = cursor }
        return (snapshotID, cursor)
    }

    @discardableResult
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public func publish(kind: EventKindID,
                        streamID: String,
                        payload: EventPayloadRef,
                        origin: EventOrigin,
                        causalSeq: UInt64? = nil,
                        causationID: String? = nil,
                        correlationID: String? = nil,
                        provenance: EventProvenance,
                        schemaVersion: UInt32 = 1) throws -> EventEnvelope {
        let spec = registry.spec(for: kind)
        let envelope: EventEnvelope
        let matchedSubscriptions: [ObservationSubscription]

        lock.lock()
        let nextSeq = (nextSeqByStream[streamID] ?? 0) + 1
        nextSeqByStream[streamID] = nextSeq
        envelope = EventEnvelope(
            eventID: "\(streamID)#\(nextSeq)",
            kind: kind,
            streamID: streamID,
            seq: nextSeq,
            causalSeq: causalSeq,
            monotonicTimestampNS: DispatchTime.now().uptimeNanoseconds,
            wallTimestampUTCMS: Int64(Date().timeIntervalSince1970 * 1000),
            origin: origin,
            causationID: causationID,
            correlationID: correlationID,
            provenance: provenance,
            payloadRef: payload,
            schemaVersion: schemaVersion,
            replay: false
        )
        var streamEvents = eventsByStream[streamID, default: []]
        streamEvents.append(envelope)
        if streamEvents.count > ringLimit {
            streamEvents.removeFirst(streamEvents.count - ringLimit)
        }
        eventsByStream[streamID] = streamEvents
        matchedSubscriptions = subscriptions.values.filter { $0.spec.filter.matches(envelope) }
        lock.unlock()

        if spec.replayable, spec.retention != .ephemeral {
            try coldLog?.append(envelope)
        }
        matchedSubscriptions.forEach { $0.enqueue(envelope) }
        return envelope
    }

    public func publish(_ draft: EventDraft) throws -> EventEnvelope {
        try publish(kind: draft.kind,
                    streamID: draft.streamID,
                    payload: draft.payloadRef,
                    origin: draft.origin,
                    causalSeq: draft.causalSeq,
                    causationID: draft.causationID,
                    correlationID: draft.correlationID,
                    provenance: draft.provenance,
                    schemaVersion: draft.schemaVersion)
    }

    public func publishBatch(_ drafts: [EventDraft]) throws -> [EventEnvelope] {
        try drafts.map { try publish($0) }
    }

    public func events(in streamID: String) -> [EventEnvelope] {
        lock.lock()
        let snapshot = eventsByStream[streamID] ?? []
        lock.unlock()
        return snapshot
    }

    public func replay(streamID: String,
                       fromSeq: UInt64,
                       toSeq: UInt64? = nil) throws -> [EventEnvelope] {
        if let coldLog {
            return try coldLog.read(streamID: streamID, fromSeq: fromSeq, toSeq: toSeq).map { envelope in
                var replayed = envelope
                replayed.replay = true
                return replayed
            }
        }
        return events(in: streamID)
            .filter { $0.seq >= fromSeq && (toSeq == nil || $0.seq <= toSeq!) }
            .map { envelope in
                var replayed = envelope
                replayed.replay = true
                return replayed
            }
    }

    private func initialEventsLocked(for spec: SubscriptionSpec) -> [EventEnvelope] {
        switch spec.startFrom {
        case .latest:
            return []
        case let .fromSeq(streamID, seq):
            return (eventsByStream[streamID] ?? []).filter { $0.seq > seq && spec.filter.matches($0) }
        case let .fromSnapshot(snapshotID):
            guard let cursor = snapshotCursors[snapshotID] else { return [] }
            return (eventsByStream[cursor.streamID] ?? [])
                .filter { $0.seq > cursor.seq && spec.filter.matches($0) }
        }
    }
}

private extension Dictionary where Key == String, Value == EventValue {
    func coalesceKey(for fields: [String]) -> String? {
        let parts = fields.compactMap { field -> String? in
            guard let value = self[field] else { return nil }
            return "\(field)=\(value.description)"
        }
        guard parts.count == fields.count else { return nil }
        return parts.joined(separator: "|")
    }
}