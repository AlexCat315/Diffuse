import Foundation
import CoreFoundation
import SIMDCompat

/// A lossless, Codable component document. Large integer identifiers and seeds
/// retain their integer representation; ordinary numbers use JSON's numeric value.
public enum ComponentValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case string(String)
    case number(Double)
    case signedInteger(Int64)
    case unsignedInteger(UInt64)
    case array([ComponentValue])
    case object([String: ComponentValue])

    public init(jsonObject value: Any) {
        switch value {
        case let value as SIMD3<Float>: self = .array([value.x, value.y, value.z].map { .number(Double($0)) })
        case let value as SIMD4<Float>: self = .array([value.x, value.y, value.z, value.w].map { .number(Double($0)) })
        case is NSNull: self = .null
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else if !["f", "d"].contains(String(cString: value.objCType)),
                      value.compare(NSNumber(value: 9_007_199_254_740_992 as UInt64)) == .orderedDescending {
                self = .unsignedInteger(value.uint64Value)
            } else if !["f", "d"].contains(String(cString: value.objCType)),
                      value.int64Value < -9_007_199_254_740_992 {
                self = .signedInteger(value.int64Value)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map(Self.init(jsonObject:)))
        case let value as [String: Any]: self = .object(value.mapValues(Self.init(jsonObject:)))
        default: preconditionFailure("Component codecs must produce JSON values: \(type(of: value))")
        }
    }

    public var jsonObject: Any {
        switch self {
        case .null: NSNull()
        case let .bool(value): value
        case let .string(value): value
        case let .number(value): value
        case let .signedInteger(value): value
        case let .unsignedInteger(value): value
        case let .array(value): value.map(\.jsonObject)
        case let .object(value): value.mapValues(\.jsonObject)
        }
    }

    public var objectValue: [String: Any]? { jsonObject as? [String: Any] }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(UInt64.self), value > 9_007_199_254_740_992 {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Int64.self), value < -9_007_199_254_740_992 {
            self = .signedInteger(value)
        } else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([ComponentValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: ComponentValue].self)) }
    }

    /// JSON has one numeric domain. Preserve integer precision while comparing
    /// equivalent numeric representations equally after Codable normalization.
    public static func == (lhs: ComponentValue, rhs: ComponentValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.signedInteger(a), .signedInteger(b)): a == b
        case let (.unsignedInteger(a), .unsignedInteger(b)): a == b
        case let (.number(a), .signedInteger(b)), let (.signedInteger(b), .number(a)):
            Int64(exactly: a) == b
        case let (.number(a), .unsignedInteger(b)), let (.unsignedInteger(b), .number(a)):
            UInt64(exactly: a) == b
        case let (.signedInteger(a), .unsignedInteger(b)), let (.unsignedInteger(b), .signedInteger(a)):
            UInt64(exactly: a) == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)): a == b
        default: false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .signedInteger(value): try container.encode(value)
        case let .unsignedInteger(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

public struct ManifestComponent: Codable, Sendable, Equatable {
    public let type: String
    public var value: ComponentValue

    public init(type: String, value: ComponentValue) {
        self.type = type
        self.value = value
    }
}

public extension Array where Element == ManifestComponent {
    func value(for typeID: String) -> ComponentValue? { first { $0.type == typeID }?.value }
}
