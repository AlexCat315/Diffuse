import Foundation

// MARK: - SymbolicEvent

/// A single LLM-safe event: binary payloads are replaced with existence markers,
/// `redact_in_prompt` events are excluded entirely, and the record is compacted.
public struct SymbolicEvent: Sendable, Equatable {
    public var kind: EventKindID
    public var streamID: String
    public var seq: UInt64
    public var causationID: String?
    public var provenance: EventProvenance
    /// Key/value summary after redaction. Handle payloads yield { "payload": "<handle>" }.
    public var summary: [String: String]

    public init(kind: EventKindID,
                streamID: String,
                seq: UInt64,
                causationID: String?,
                provenance: EventProvenance,
                summary: [String: String]) {
        self.kind = kind
        self.streamID = streamID
        self.seq = seq
        self.causationID = causationID
        self.provenance = provenance
        self.summary = summary
    }
}

// MARK: - EventSymbolicViewWindow

/// Describes which part of the bus ring the view covers.
public struct EventSymbolicViewWindow: Sendable, Equatable {
    public var streamID: String
    public var fromSeq: UInt64
    public var toSeq: UInt64
    public var maxCount: Int

    public init(streamID: String, fromSeq: UInt64, toSeq: UInt64, maxCount: Int) {
        self.streamID = streamID
        self.fromSeq = fromSeq
        self.toSeq = toSeq
        self.maxCount = maxCount
    }
}

// MARK: - EventSymbolicView

/// The LLM-facing view of a bus window: redacted, filtered, and compacted.
///
/// Build it via `ObservationBus.symbolicView(streamID:fromSeq:maxCount:)`.
///
/// Exclusion rules (from design §15):
/// 1. Kinds whose `redactInPrompt == true` are dropped entirely.
/// 2. `runtime.tick` and `runtime.metric.sampled` are dropped.
/// 3. Handle payloads yield `{ "payload": "<handle:store/key>" }` instead of bytes.
/// 4. Deeply nested objects are compacted to their top-level keys only.
public struct EventSymbolicView: Sendable, Equatable {
    public var window: EventSymbolicViewWindow
    public var events: [SymbolicEvent]

    public init(window: EventSymbolicViewWindow, events: [SymbolicEvent]) {
        self.window = window
        self.events = events
    }

    /// Renders the view as a compact multi-line string for LLM injection.
    public func promptText() -> String {
        guard !events.isEmpty else { return "(no recent observable events)" }
        var lines: [String] = ["Recent events (stream: \(window.streamID), seq \(window.fromSeq)–\(window.toSeq)):"]
        for ev in events {
            var parts: [String] = ["  [\(ev.seq)] \(ev.kind.rawValue)"]
            if let cid = ev.causationID { parts.append("cause=\(cid)") }
            if ev.provenance != .authored { parts.append("prov=\(ev.provenance.rawValue)") }
            if !ev.summary.isEmpty {
                let kv = ev.summary.sorted(by: { $0.key < $1.key })
                                   .map { "\($0.key)=\($0.value)" }
                                   .joined(separator: " ")
                parts.append(kv)
            }
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - ObservationBus extension

extension ObservationBus {
    private static let excludedFromPrompt: Set<EventKindID> = [.runtimeTick, .runtimeMetricSampled]

    /// Returns a symbolic (LLM-safe) view of recent events in `streamID`.
    ///
    /// - Parameters:
    ///   - streamID: The stream to read from.
    ///   - fromSeq: Inclusive lower bound (0 = all available in ring).
    ///   - maxCount: Maximum number of symbolic events to include.
    public func symbolicView(streamID: String,
                             fromSeq: UInt64 = 0,
                             maxCount: Int = 50) -> EventSymbolicView {
        let raw = events(in: streamID).filter { $0.seq >= fromSeq }
        let filtered = raw.filter { envelope in
            !Self.excludedFromPrompt.contains(envelope.kind) &&
            !registry.spec(for: envelope.kind).redactInPrompt
        }
        let capped = filtered.suffix(maxCount)
        let symbolic = capped.map { symbolicate($0) }
        let fromSeqActual = capped.first?.seq ?? fromSeq
        let toSeqActual = capped.last?.seq ?? fromSeq
        let window = EventSymbolicViewWindow(streamID: streamID,
                                            fromSeq: fromSeqActual,
                                            toSeq: toSeqActual,
                                            maxCount: maxCount)
        return EventSymbolicView(window: window, events: symbolic)
    }

    private func symbolicate(_ envelope: EventEnvelope) -> SymbolicEvent {
        let summary: [String: String]
        switch envelope.payloadRef {
        case let .inline(record):
            summary = compactSummary(record)
        case let .handle(handle):
            summary = ["payload": "<handle:\(handle.store)/\(handle.key)>"]
        }
        return SymbolicEvent(
            kind: envelope.kind,
            streamID: envelope.streamID,
            seq: envelope.seq,
            causationID: envelope.causationID,
            provenance: envelope.provenance,
            summary: summary
        )
    }

    private func compactSummary(_ record: EventPayloadRecord) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in record {
            switch value {
            case let .string(s):
                out[key] = s.count > 120 ? String(s.prefix(120)) + "…" : s
            case let .integer(i):
                out[key] = String(i)
            case let .number(n):
                out[key] = String(format: "%.4g", n)
            case let .boolean(b):
                out[key] = b ? "true" : "false"
            case .array:
                out[key] = "<array>"
            case .object:
                out[key] = "<object>"
            case .null:
                out[key] = "null"
            }
        }
        return out
    }
}
