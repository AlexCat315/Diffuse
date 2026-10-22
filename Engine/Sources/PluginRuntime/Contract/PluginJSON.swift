import Foundation

/// Any JSON value a manifest carries through for another program, such as a
/// language server's options.
public enum PluginJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PluginJSON])
    case object([String: PluginJSON])

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([PluginJSON].self) { self = .array(array) }
        else { self = .object(try value.decode([String: PluginJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case let .bool(bool): try value.encode(bool)
        case let .number(number): try value.encode(number)
        case let .string(string): try value.encode(string)
        case let .array(array): try value.encode(array)
        case let .object(object): try value.encode(object)
        }
    }

    /// The value as `JSONSerialization` objects.
    public var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case let .bool(bool): bool
        case let .number(number): number.rounded() == number && abs(number) < 1e15 ? Int(number) as Any : number
        case let .string(string): string
        case let .array(array): array.map(\.foundationValue)
        case let .object(object): object.mapValues(\.foundationValue)
        }
    }
}
