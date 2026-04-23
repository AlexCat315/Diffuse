import Foundation

public typealias EventPayloadRecord = [String: EventValue]

public enum EventValue: Sendable, Equatable, Codable, CustomStringConvertible {
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case array([EventValue])
    case object(EventPayloadRecord)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(EventPayloadRecord.self) {
            self = .object(value)
            return
        }
        if let value = try? container.decode([EventValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container,
                                               debugDescription: "unsupported EventValue payload")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .boolean(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var description: String {
        switch self {
        case let .string(value):
            return value
        case let .integer(value):
            return String(value)
        case let .number(value):
            return String(value)
        case let .boolean(value):
            return String(value)
        case let .array(value):
            return "[\(value.map(\ .description).joined(separator: ","))]"
        case let .object(value):
            return "{\(value.map { "\($0.key)=\($0.value.description)" }.sorted().joined(separator: ","))}"
        case .null:
            return "null"
        }
    }
}

public struct EventPayloadHandle: Sendable, Equatable, Codable {
    public var store: String
    public var key: String
    public var contentHash: String

    public init(store: String, key: String, contentHash: String) {
        self.store = store
        self.key = key
        self.contentHash = contentHash
    }
}

public enum EventPayloadRef: Sendable, Equatable, Codable {
    case inline(record: EventPayloadRecord)
    case handle(EventPayloadHandle)

    enum CodingKeys: String, CodingKey {
        case kind
        case record
        case handle
    }

    enum Kind: String, Codable {
        case inline
        case handle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .inline:
            self = .inline(record: try container.decode(EventPayloadRecord.self, forKey: .record))
        case .handle:
            self = .handle(try container.decode(EventPayloadHandle.self, forKey: .handle))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .inline(record):
            try container.encode(Kind.inline, forKey: .kind)
            try container.encode(record, forKey: .record)
        case let .handle(handle):
            try container.encode(Kind.handle, forKey: .kind)
            try container.encode(handle, forKey: .handle)
        }
    }

    public static func inline(_ record: EventPayloadRecord) -> EventPayloadRef {
        .inline(record: record)
    }

    public var inlineRecord: EventPayloadRecord? {
        guard case let .inline(record) = self else { return nil }
        return record
    }
}

public enum EventOriginProcessKind: String, Sendable, Equatable, Codable {
    case editor
    case runtime
    case renderFarm = "render_farm"
    case tool
}

public struct EventOrigin: Sendable, Equatable, Codable {
    public var process: EventOriginProcessKind
    public var host: String
    public var user: String?
    public var agent: String?

    public init(process: EventOriginProcessKind,
                host: String,
                user: String? = nil,
                agent: String? = nil) {
        self.process = process
        self.host = host
        self.user = user
        self.agent = agent
    }

    public static func tool(user: String? = nil, agent: String? = nil) -> EventOrigin {
        EventOrigin(process: .tool,
                    host: ProcessInfo.processInfo.hostName,
                    user: user,
                    agent: agent)
    }
}

public enum EventProvenance: String, Sendable, Equatable, Codable {
    case authored
    case evaluated
    case runtime
    case baked
    case inferred
}

public struct EventEnvelope: Sendable, Equatable, Codable {
    public var eventID: String
    public var kind: EventKindID
    public var streamID: String
    public var seq: UInt64
    public var causalSeq: UInt64?
    public var monotonicTimestampNS: UInt64
    public var wallTimestampUTCMS: Int64
    public var origin: EventOrigin
    public var causationID: String?
    public var correlationID: String?
    public var provenance: EventProvenance
    public var payloadRef: EventPayloadRef
    public var schemaVersion: UInt32
    public var replay: Bool

    public init(eventID: String,
                kind: EventKindID,
                streamID: String,
                seq: UInt64,
                causalSeq: UInt64? = nil,
                monotonicTimestampNS: UInt64,
                wallTimestampUTCMS: Int64,
                origin: EventOrigin,
                causationID: String? = nil,
                correlationID: String? = nil,
                provenance: EventProvenance,
                payloadRef: EventPayloadRef,
                schemaVersion: UInt32 = 1,
                replay: Bool = false) {
        self.eventID = eventID
        self.kind = kind
        self.streamID = streamID
        self.seq = seq
        self.causalSeq = causalSeq
        self.monotonicTimestampNS = monotonicTimestampNS
        self.wallTimestampUTCMS = wallTimestampUTCMS
        self.origin = origin
        self.causationID = causationID
        self.correlationID = correlationID
        self.provenance = provenance
        self.payloadRef = payloadRef
        self.schemaVersion = schemaVersion
        self.replay = replay
    }
}