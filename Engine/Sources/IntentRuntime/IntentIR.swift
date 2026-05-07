import Foundation
import simd

public enum IntentSource: String, Sendable, Equatable, Codable {
    case human
    case ai
    case system
}

public struct IntentVector3: Sendable, Equatable, Codable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(_ value: SIMD3<Float>) {
        self.init(x: value.x, y: value.y, z: value.z)
    }

    public var simdValue: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}

public enum IntentArgumentValue: Sendable, Equatable, Codable {
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case stableID(UInt64)
    case vec3(IntentVector3)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum Kind: String, Codable {
        case bool
        case integer
        case number
        case string
        case stableID = "stable_id"
        case vec3
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .value))
        case .number:
            self = .number(try container.decode(Double.self, forKey: .value))
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .stableID:
            self = .stableID(try container.decode(UInt64.self, forKey: .value))
        case .vec3:
            self = .vec3(try container.decode(IntentVector3.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .bool(value):
            try container.encode(Kind.bool, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .number(value):
            try container.encode(Kind.number, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .string(value):
            try container.encode(Kind.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .stableID(value):
            try container.encode(Kind.stableID, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .vec3(value):
            try container.encode(Kind.vec3, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

public struct IntentEvidence: Sendable, Equatable, Codable {
    public var kind: String
    public var summary: String
    public var targetObjectID: String?

    public init(kind: String,
                summary: String,
                targetObjectID: String? = nil) {
        self.kind = kind
        self.summary = summary
        self.targetObjectID = targetObjectID
    }
}

public struct IntentIR: Sendable, Equatable, Codable {
    public var id: String
    public var verb: String
    public var summary: String
    public var targetObjectIDs: [String]
    public var arguments: [String: IntentArgumentValue]
    public var confidence: Double
    public var evidence: [IntentEvidence]
    public var source: IntentSource
    public var createdAt: Date

    public init(id: String = UUID().uuidString,
                verb: String,
                summary: String,
                targetObjectIDs: [String] = [],
                arguments: [String: IntentArgumentValue] = [:],
                confidence: Double = 1.0,
                evidence: [IntentEvidence] = [],
                source: IntentSource,
                createdAt: Date = Date()) {
        self.id = id
        self.verb = verb
        self.summary = summary
        self.targetObjectIDs = targetObjectIDs
        self.arguments = arguments
        self.confidence = confidence
        self.evidence = evidence
        self.source = source
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case verb
        case summary
        case targetObjectIDs
        case arguments
        case confidence
        case evidence
        case source
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
                  verb: try container.decode(String.self, forKey: .verb),
                  summary: try container.decode(String.self, forKey: .summary),
                  targetObjectIDs: try container.decodeIfPresent([String].self, forKey: .targetObjectIDs) ?? [],
                  arguments: try container.decodeIfPresent([String: IntentArgumentValue].self, forKey: .arguments) ?? [:],
                  confidence: try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0,
                  evidence: try container.decodeIfPresent([IntentEvidence].self, forKey: .evidence) ?? [],
                  source: try container.decode(IntentSource.self, forKey: .source),
                  createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date())
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(verb, forKey: .verb)
        try container.encode(summary, forKey: .summary)
        try container.encode(targetObjectIDs, forKey: .targetObjectIDs)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(source, forKey: .source)
        try container.encode(createdAt, forKey: .createdAt)
    }
}
