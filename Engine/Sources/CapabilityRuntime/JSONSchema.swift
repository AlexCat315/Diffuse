import Foundation
import CoreFoundation

/// The JSON types supported by Guava capability inputs.
public enum JSONSchemaType: String, Codable, Sendable, Equatable {
    case object
    case array
    case string
    case number
    case integer
    case boolean
    case null
}

/// A scalar value used by a JSON Schema `enum` constraint.
public enum JSONSchemaScalar: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        }
    }

    fileprivate var jsonObject: Any {
        switch self {
        case let .string(value): return value
        case let .number(value): return value
        case let .boolean(value): return value
        }
    }
}

/// A small, strict JSON Schema representation shared by AI providers, MCP, and
/// capability argument validation. It deliberately supports only the subset of
/// JSON Schema that Guava capability inputs are allowed to use.
///
/// Recursive children live in arrays/dictionaries so the value remains a normal
/// Sendable struct without reference identity.
public struct JSONSchema: Codable, Sendable, Equatable {
    public var type: JSONSchemaType?
    public var description: String?
    public var properties: [String: JSONSchema]
    public var required: [String]
    public var items: [JSONSchema]
    public var allowedValues: [JSONSchemaScalar]
    public var oneOf: [JSONSchema]
    public var additionalProperties: Bool?
    public var minimum: Double?
    public var maximum: Double?
    public var minimumItems: Int?
    public var maximumItems: Int?
    public var minimumLength: Int?
    public var maximumLength: Int?
    public var pattern: String?

    public init(type: JSONSchemaType? = nil,
                description: String? = nil,
                properties: [String: JSONSchema] = [:],
                required: [String] = [],
                items: [JSONSchema] = [],
                allowedValues: [JSONSchemaScalar] = [],
                oneOf: [JSONSchema] = [],
                additionalProperties: Bool? = nil,
                minimum: Double? = nil,
                maximum: Double? = nil,
                minimumItems: Int? = nil,
                maximumItems: Int? = nil,
                minimumLength: Int? = nil,
                maximumLength: Int? = nil,
                pattern: String? = nil) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required.sorted()
        self.items = items
        self.allowedValues = allowedValues
        self.oneOf = oneOf
        self.additionalProperties = additionalProperties
        self.minimum = minimum
        self.maximum = maximum
        self.minimumItems = minimumItems
        self.maximumItems = maximumItems
        self.minimumLength = minimumLength
        self.maximumLength = maximumLength
        self.pattern = pattern
    }

    public static func object(properties: [String: JSONSchema],
                              required: [String] = [],
                              description: String? = nil,
                              additionalProperties: Bool = false) -> JSONSchema {
        let requiredKeys = Set(required)
        let optionalAwareProperties = properties.mapValuesWithKeys { key, schema in
            requiredKeys.contains(key) ? schema : schema.acceptingNull
        }
        return JSONSchema(type: .object,
                          description: description,
                          properties: optionalAwareProperties,
                          required: required,
                          additionalProperties: additionalProperties)
    }

    public static func array(of item: JSONSchema,
                             description: String? = nil,
                             minimumItems: Int? = nil,
                             maximumItems: Int? = nil) -> JSONSchema {
        JSONSchema(type: .array,
                   description: description,
                   items: [item],
                   minimumItems: minimumItems,
                   maximumItems: maximumItems)
    }

    public static func string(description: String? = nil,
                              allowedValues: [String] = []) -> JSONSchema {
        JSONSchema(type: .string,
                   description: description,
                   allowedValues: allowedValues.map(JSONSchemaScalar.string))
    }

    public static func string(description: String? = nil,
                              allowedValues: [String] = [],
                              minLength: Int?,
                              maxLength: Int?,
                              pattern: String? = nil) -> JSONSchema {
        JSONSchema(type: .string,
                   description: description,
                   allowedValues: allowedValues.map(JSONSchemaScalar.string),
                   minimumLength: minLength,
                   maximumLength: maxLength,
                   pattern: pattern)
    }

    public static func number(description: String? = nil,
                              minimum: Double? = nil,
                              maximum: Double? = nil) -> JSONSchema {
        JSONSchema(type: .number,
                   description: description,
                   minimum: minimum,
                   maximum: maximum)
    }

    public static func integer(description: String? = nil,
                               minimum: Int? = nil,
                               maximum: Int? = nil) -> JSONSchema {
        JSONSchema(type: .integer,
                   description: description,
                   minimum: minimum.map(Double.init),
                   maximum: maximum.map(Double.init))
    }

    public static func boolean(description: String? = nil) -> JSONSchema {
        JSONSchema(type: .boolean, description: description)
    }

    public static func null(description: String? = nil) -> JSONSchema {
        JSONSchema(type: .null, description: description)
    }

    public static func any(description: String? = nil) -> JSONSchema {
        JSONSchema(description: description)
    }

    public static func choice(_ alternatives: [JSONSchema],
                              description: String? = nil) -> JSONSchema {
        JSONSchema(description: description, oneOf: alternatives)
    }

    private var acceptingNull: JSONSchema {
        if type == nil, oneOf.isEmpty { return self }
        if type == .null || oneOf.contains(where: { $0.type == .null }) { return self }
        return .choice([self, .null()])
    }

    /// True only for the bounded schema subset allowed on write-capability
    /// boundaries. In particular, untyped `any` values and open nested objects
    /// are rejected even when the root object is strict.
    public var isStrictCapabilityInput: Bool {
        if !oneOf.isEmpty {
            return type == nil && !oneOf.isEmpty && oneOf.allSatisfy(\.isStrictCapabilityInput)
        }
        switch type {
        case .object:
            return additionalProperties == false
                && properties.values.allSatisfy(\.isStrictCapabilityInput)
        case .array:
            return items.count == 1 && items[0].isStrictCapabilityInput
        case .string, .number, .integer, .boolean, .null:
            return true
        case nil:
            return false
        }
    }

    /// Foundation object suitable for Anthropic, OpenAI-compatible, and MCP payloads.
    public func jsonObject() -> [String: Any] {
        var result: [String: Any] = [:]
        if let type { result["type"] = type.rawValue }
        if let description { result["description"] = description }
        if !properties.isEmpty {
            result["properties"] = properties.mapValues { $0.jsonObject() }
        }
        if !required.isEmpty { result["required"] = required.sorted() }
        if let item = items.first { result["items"] = item.jsonObject() }
        if !allowedValues.isEmpty { result["enum"] = allowedValues.map(\.jsonObject) }
        if !oneOf.isEmpty { result["oneOf"] = oneOf.map { $0.jsonObject() } }
        if let additionalProperties { result["additionalProperties"] = additionalProperties }
        if let minimum { result["minimum"] = minimum }
        if let maximum { result["maximum"] = maximum }
        if let minimumItems { result["minItems"] = minimumItems }
        if let maximumItems { result["maxItems"] = maximumItems }
        if let minimumLength { result["minLength"] = minimumLength }
        if let maximumLength { result["maxLength"] = maximumLength }
        if let pattern { result["pattern"] = pattern }
        return result
    }

    /// Canonical JSON used by capability contract fingerprints.
    public func canonicalData() -> Data {
        // Every object produced by jsonObject is JSON-serialisable by construction.
        (try? JSONSerialization.data(withJSONObject: jsonObject(), options: [.sortedKeys])) ?? Data()
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case description
        case properties
        case required
        case items
        case allowedValues = "enum"
        case oneOf
        case additionalProperties
        case minimum
        case maximum
        case minimumItems = "minItems"
        case maximumItems = "maxItems"
        case minimumLength = "minLength"
        case maximumLength = "maxLength"
        case pattern
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(JSONSchemaType.self, forKey: .type)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        properties = try container.decodeIfPresent([String: JSONSchema].self, forKey: .properties) ?? [:]
        required = (try container.decodeIfPresent([String].self, forKey: .required) ?? []).sorted()
        if let item = try container.decodeIfPresent(JSONSchema.self, forKey: .items) {
            items = [item]
        } else {
            items = []
        }
        allowedValues = try container.decodeIfPresent([JSONSchemaScalar].self, forKey: .allowedValues) ?? []
        oneOf = try container.decodeIfPresent([JSONSchema].self, forKey: .oneOf) ?? []
        additionalProperties = try container.decodeIfPresent(Bool.self, forKey: .additionalProperties)
        minimum = try container.decodeIfPresent(Double.self, forKey: .minimum)
        maximum = try container.decodeIfPresent(Double.self, forKey: .maximum)
        minimumItems = try container.decodeIfPresent(Int.self, forKey: .minimumItems)
        maximumItems = try container.decodeIfPresent(Int.self, forKey: .maximumItems)
        minimumLength = try container.decodeIfPresent(Int.self, forKey: .minimumLength)
        maximumLength = try container.decodeIfPresent(Int.self, forKey: .maximumLength)
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(description, forKey: .description)
        if !properties.isEmpty { try container.encode(properties, forKey: .properties) }
        if !required.isEmpty { try container.encode(required.sorted(), forKey: .required) }
        if let item = items.first { try container.encode(item, forKey: .items) }
        if !allowedValues.isEmpty { try container.encode(allowedValues, forKey: .allowedValues) }
        if !oneOf.isEmpty { try container.encode(oneOf, forKey: .oneOf) }
        try container.encodeIfPresent(additionalProperties, forKey: .additionalProperties)
        try container.encodeIfPresent(minimum, forKey: .minimum)
        try container.encodeIfPresent(maximum, forKey: .maximum)
        try container.encodeIfPresent(minimumItems, forKey: .minimumItems)
        try container.encodeIfPresent(maximumItems, forKey: .maximumItems)
        try container.encodeIfPresent(minimumLength, forKey: .minimumLength)
        try container.encodeIfPresent(maximumLength, forKey: .maximumLength)
        try container.encodeIfPresent(pattern, forKey: .pattern)
    }
}

public struct JSONSchemaViolation: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public var path: String
    public var reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    public var description: String { "\(path): \(reason)" }
}

/// Host-side validation is authoritative even when a model provider advertises
/// strict tool schemas. Provider validation is treated as a convenience only.
public enum JSONSchemaValidator {
    public static func validate(data: Data, against schema: JSONSchema) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONSchemaViolation(path: "$", reason: "invalid JSON")
        }
        try validate(value, against: schema, path: "$")
    }

    public static func validate(_ value: Any, against schema: JSONSchema) throws {
        try validate(value, against: schema, path: "$")
    }

    private static func validate(_ value: Any,
                                 against schema: JSONSchema,
                                 path: String) throws {
        if !schema.oneOf.isEmpty {
            let matches = schema.oneOf.reduce(into: 0) { count, candidate in
                if (try? validate(value, against: candidate, path: path)) != nil { count += 1 }
            }
            guard matches == 1 else {
                throw JSONSchemaViolation(path: path,
                                          reason: "must match exactly one allowed schema (matched \(matches))")
            }
        }

        switch schema.type {
        case .object:
            guard let object = value as? [String: Any] else {
                throw JSONSchemaViolation(path: path, reason: "expected object")
            }
            for key in schema.required where object[key] == nil {
                throw JSONSchemaViolation(path: path, reason: "missing required property '\(key)'")
            }
            if schema.additionalProperties == false,
               let unknown = object.keys.first(where: { schema.properties[$0] == nil }) {
                throw JSONSchemaViolation(path: path, reason: "unknown property '\(unknown)'")
            }
            for (key, child) in object {
                if let childSchema = schema.properties[key] {
                    try validate(child, against: childSchema, path: "\(path).\(key)")
                }
            }

        case .array:
            guard let values = value as? [Any] else {
                throw JSONSchemaViolation(path: path, reason: "expected array")
            }
            if let minimumItems = schema.minimumItems, values.count < minimumItems {
                throw JSONSchemaViolation(path: path, reason: "requires at least \(minimumItems) items")
            }
            if let maximumItems = schema.maximumItems, values.count > maximumItems {
                throw JSONSchemaViolation(path: path, reason: "allows at most \(maximumItems) items")
            }
            if let itemSchema = schema.items.first {
                for (index, child) in values.enumerated() {
                    try validate(child, against: itemSchema, path: "\(path)[\(index)]")
                }
            }

        case .string:
            guard let string = value as? String else {
                throw JSONSchemaViolation(path: path, reason: "expected string")
            }
            if let minimumLength = schema.minimumLength, string.count < minimumLength {
                throw JSONSchemaViolation(path: path, reason: "requires at least \(minimumLength) characters")
            }
            if let maximumLength = schema.maximumLength, string.count > maximumLength {
                throw JSONSchemaViolation(path: path, reason: "allows at most \(maximumLength) characters")
            }
            if let pattern = schema.pattern,
               string.range(of: pattern, options: .regularExpression) == nil {
                throw JSONSchemaViolation(path: path, reason: "does not match required pattern")
            }
        case .number:
            guard numericValue(value) != nil else {
                throw JSONSchemaViolation(path: path, reason: "expected number")
            }
        case .integer:
            guard let number = numericValue(value), number.rounded() == number else {
                throw JSONSchemaViolation(path: path, reason: "expected integer")
            }
        case .boolean:
            guard booleanValue(value) != nil else {
                throw JSONSchemaViolation(path: path, reason: "expected boolean")
            }
        case .null:
            guard value is NSNull else {
                throw JSONSchemaViolation(path: path, reason: "expected null")
            }
        case nil:
            break
        }

        if let number = numericValue(value) {
            if let minimum = schema.minimum, number < minimum {
                throw JSONSchemaViolation(path: path, reason: "must be >= \(minimum)")
            }
            if let maximum = schema.maximum, number > maximum {
                throw JSONSchemaViolation(path: path, reason: "must be <= \(maximum)")
            }
        }

        if !schema.allowedValues.isEmpty {
            let matches = schema.allowedValues.contains { scalar in
                switch scalar {
                case let .string(candidate): return (value as? String) == candidate
                case let .number(candidate): return numericValue(value) == candidate
                case let .boolean(candidate): return booleanValue(value) == candidate
                }
            }
            guard matches else {
                throw JSONSchemaViolation(path: path, reason: "value is not in the allowed enum")
            }
        }
    }

    private static func numericValue(_ value: Any) -> Double? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.doubleValue
        }
        switch value {
        case let value as Int: return Double(value)
        case let value as Int8: return Double(value)
        case let value as Int16: return Double(value)
        case let value as Int32: return Double(value)
        case let value as Int64: return Double(value)
        case let value as UInt: return Double(value)
        case let value as UInt8: return Double(value)
        case let value as UInt16: return Double(value)
        case let value as UInt32: return Double(value)
        case let value as UInt64: return Double(value)
        case let value as Float: return Double(value)
        case let value as Double: return value
        default: return nil
        }
    }

    private static func booleanValue(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

private extension Dictionary {
    func mapValuesWithKeys<NewValue>(_ transform: (Key, Value) throws -> NewValue) rethrows
        -> [Key: NewValue] {
        try Dictionary<Key, NewValue>(uniqueKeysWithValues: map { key, value in
            (key, try transform(key, value))
        })
    }
}
