import Foundation

/// Scalar property value carried by a WorldEvent state change.
public enum WorldPropertyValue: Sendable, Equatable, Codable {
    case vec3(Float, Float, Float)
    case float(Float)
    case string(String)
    case bool(Bool)

    private enum CodingKeys: String, CodingKey { case type, x, y, z, value }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .vec3(x, y, z):
            try c.encode("vec3", forKey: .type)
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y); try c.encode(z, forKey: .z)
        case let .float(v):
            try c.encode("float", forKey: .type); try c.encode(v, forKey: .value)
        case let .string(s):
            try c.encode("string", forKey: .type); try c.encode(s, forKey: .value)
        case let .bool(b):
            try c.encode("bool", forKey: .type); try c.encode(b, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "vec3":
            self = .vec3(try c.decode(Float.self, forKey: .x),
                         try c.decode(Float.self, forKey: .y),
                         try c.decode(Float.self, forKey: .z))
        case "float":  self = .float(try c.decode(Float.self, forKey: .value))
        case "string": self = .string(try c.decode(String.self, forKey: .value))
        case "bool":   self = .bool(try c.decode(Bool.self, forKey: .value))
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown WorldPropertyValue type"))
        }
    }
}

/// A fine-grained World state change emitted by TransactionExecutor on every apply().
///
/// Session feeds these into WorldView.apply(event:) to maintain an incremental entity index
/// without full-snapshot refreshes — the Phase 5 migration of the snapshot path to delta-driven.
public enum WorldEvent: Sendable, Equatable {
    /// An entity was created (spawned or duplicated).
    case entityAdded(ref: String, name: String, kind: String?)
    /// An entity was permanently removed from the World.
    case entityRemoved(ref: String)
    /// An authored property on an entity was changed by a user or AI action.
    case entityAuthoredChanged(ref: String, property: String, value: WorldPropertyValue)
    /// An Edit was applied to the World — carries the revision bump.
    case editApplied(editID: String, summary: String, revision: UInt64)
    /// The active selection set changed.
    case selectionChanged(refs: [String])

    // MARK: - Phase 5b

    /// An engine-computed property changed (e.g. world-space transform after hierarchy solve).
    /// Emitted by the engine after each simulation/render tick that changes derived state.
    case entityEvaluatedChanged(ref: String, property: String, value: WorldPropertyValue)
    /// AI inferred a semantic property on an entity (e.g. role, mood, movement pattern).
    /// Emitted by the semantic pipeline or Session after analysing scene content.
    case entityInferredUpdated(ref: String,
                               property: String,
                               value: WorldPropertyValue,
                               confidence: Double,
                               source: String?)
}
