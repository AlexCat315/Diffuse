import CapabilityRuntime
import Foundation

/// Values allowed on the generated capability-input boundary. Conforming a new
/// engine value type is an explicit host decision; arbitrary dictionaries and
/// untyped JSON therefore cannot silently become AI-write parameters.
public protocol CapabilitySchemaValue: Codable, Sendable {
    static var capabilitySchema: JSONSchema { get }
    static var capabilityPlaceholder: Self { get }
    static var capabilityIsOptional: Bool { get }
}

public extension CapabilitySchemaValue {
    static var capabilityIsOptional: Bool { false }
}

extension String: CapabilitySchemaValue {
    public static var capabilitySchema: JSONSchema { .string() }
    public static var capabilityPlaceholder: String { "" }
}

extension Bool: CapabilitySchemaValue {
    public static var capabilitySchema: JSONSchema { .boolean() }
    public static var capabilityPlaceholder: Bool { false }
}

extension Int: CapabilitySchemaValue {
    public static var capabilitySchema: JSONSchema { .integer() }
    public static var capabilityPlaceholder: Int { 0 }
}

extension Float: CapabilitySchemaValue {
    public static var capabilitySchema: JSONSchema { .number() }
    public static var capabilityPlaceholder: Float { 0 }
}

extension Double: CapabilitySchemaValue {
    public static var capabilitySchema: JSONSchema { .number() }
    public static var capabilityPlaceholder: Double { 0 }
}

extension Optional: CapabilitySchemaValue where Wrapped: CapabilitySchemaValue {
    public static var capabilitySchema: JSONSchema { Wrapped.capabilitySchema }
    public static var capabilityPlaceholder: Wrapped? { nil }
    public static var capabilityIsOptional: Bool { true }
}

extension Array: CapabilitySchemaValue where Element: CapabilitySchemaValue {
    public static var capabilitySchema: JSONSchema { .array(of: Element.capabilitySchema) }
    public static var capabilityPlaceholder: [Element] { [] }
}

/// A validated scene reference. Invalid references are rejected by both the
/// generated schema and the Swift decoder.
public struct SceneEntityRef: CapabilitySchemaValue, Equatable, Hashable {
    public var rawValue: String

    public init(_ rawValue: String) throws {
        guard rawValue.range(of: #"^scene:[0-9]+$"#, options: .regularExpression) != nil else {
            throw SceneEntityRefError.invalidFormat(rawValue)
        }
        self.rawValue = rawValue
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        try self.init(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static var capabilitySchema: JSONSchema {
        .string(description: "Entity reference in scene:<number> format.",
                minLength: 7,
                maxLength: 32,
                pattern: #"^scene:[0-9]+$"#)
    }

    public static var capabilityPlaceholder: SceneEntityRef {
        SceneEntityRef(unchecked: "scene:0")
    }
}

public enum SceneEntityRefError: Error, Sendable, Equatable {
    case invalidFormat(String)
}

public struct Vec2: CapabilitySchemaValue, Equatable {
    public var x: Double
    public var y: Double

    public init(_ x: Double = 0, _ y: Double = 0) {
        self.x = x
        self.y = y
    }

    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        x = try values.decode(Double.self)
        y = try values.decode(Double.self)
        guard values.isAtEnd else { throw CapabilityVectorError.invalidElementCount(expected: 2) }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(x)
        try values.encode(y)
    }

    public static var capabilitySchema: JSONSchema {
        .array(of: .number(), minimumItems: 2, maximumItems: 2)
    }
    public static var capabilityPlaceholder: Vec2 { Vec2() }
}

public struct Vec3: CapabilitySchemaValue, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        x = try values.decode(Double.self)
        y = try values.decode(Double.self)
        z = try values.decode(Double.self)
        guard values.isAtEnd else { throw CapabilityVectorError.invalidElementCount(expected: 3) }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(x)
        try values.encode(y)
        try values.encode(z)
    }

    public static var capabilitySchema: JSONSchema {
        .array(of: .number(), minimumItems: 3, maximumItems: 3)
    }
    public static var capabilityPlaceholder: Vec3 { Vec3() }
}

public struct Vec4: CapabilitySchemaValue, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0, _ w: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        x = try values.decode(Double.self)
        y = try values.decode(Double.self)
        z = try values.decode(Double.self)
        w = try values.decode(Double.self)
        guard values.isAtEnd else { throw CapabilityVectorError.invalidElementCount(expected: 4) }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(x)
        try values.encode(y)
        try values.encode(z)
        try values.encode(w)
    }

    public static var capabilitySchema: JSONSchema {
        .array(of: .number(), minimumItems: 4, maximumItems: 4)
    }
    public static var capabilityPlaceholder: Vec4 { Vec4() }
}

public enum CapabilityVectorError: Error, Sendable, Equatable {
    case invalidElementCount(expected: Int)
}

private protocol AnyDeclaredCapabilityField {
    var declaredSchema: JSONSchema { get }
    var isOptional: Bool { get }
}

@propertyWrapper
public struct AIField<Value: CapabilitySchemaValue>: Codable, Sendable {
    public var wrappedValue: Value
    public var description: String
    public var minimum: Double?
    public var maximum: Double?
    public var minimumLength: Int?
    public var maximumLength: Int?
    public var pattern: String?

    public init(wrappedValue: Value,
                description: String = "",
                minimum: Double? = nil,
                maximum: Double? = nil,
                minLength: Int? = nil,
                maxLength: Int? = nil,
                pattern: String? = nil) {
        self.wrappedValue = wrappedValue
        self.description = description
        self.minimum = minimum
        self.maximum = maximum
        self.minimumLength = minLength
        self.maximumLength = maxLength
        self.pattern = pattern
    }

    public init(description: String = "",
                minimum: Double? = nil,
                maximum: Double? = nil,
                minLength: Int? = nil,
                maxLength: Int? = nil,
                pattern: String? = nil) {
        self.init(wrappedValue: Value.capabilityPlaceholder,
                  description: description,
                  minimum: minimum,
                  maximum: maximum,
                  minLength: minLength,
                  maxLength: maxLength,
                  pattern: pattern)
    }

    public init(from decoder: Decoder) throws {
        wrappedValue = try Value(from: decoder)
        description = ""
        minimum = nil
        maximum = nil
        minimumLength = nil
        maximumLength = nil
        pattern = nil
    }

    public func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
}

extension AIField: AnyDeclaredCapabilityField {
    fileprivate var declaredSchema: JSONSchema {
        Value.capabilitySchema.applying(description: description,
                                        minimum: minimum,
                                        maximum: maximum,
                                        minimumLength: minimumLength,
                                        maximumLength: maximumLength,
                                        pattern: pattern)
    }
    fileprivate var isOptional: Bool { Value.capabilityIsOptional }
}

@propertyWrapper
public struct ValueRange<Value: CapabilitySchemaValue>: Codable, Sendable {
    public var wrappedValue: Value
    public var minimum: Double?
    public var maximum: Double?

    public init(wrappedValue: Value, min: Double? = nil, max: Double? = nil) {
        self.wrappedValue = wrappedValue
        minimum = min
        maximum = max
    }

    public init(min: Double? = nil, max: Double? = nil) {
        self.init(wrappedValue: Value.capabilityPlaceholder, min: min, max: max)
    }

    public init(from decoder: Decoder) throws {
        wrappedValue = try Value(from: decoder)
        minimum = nil
        maximum = nil
    }

    public func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
}

extension ValueRange: AnyDeclaredCapabilityField {
    fileprivate var declaredSchema: JSONSchema {
        Value.capabilitySchema.applying(description: nil,
                                        minimum: minimum,
                                        maximum: maximum,
                                        minimumLength: nil,
                                        maximumLength: nil,
                                        pattern: nil)
    }
    fileprivate var isOptional: Bool { Value.capabilityIsOptional }
}

public enum SceneComponentRequirement: String, Codable, Sendable, Equatable {
    case localTransform = "LocalTransform"
    case rigidBody = "RigidBody"
    case collider = "Collider"
    case light = "LightComponent"
    case camera = "CameraComponent"
    case renderMesh = "RenderMeshComponent"
}

@propertyWrapper
public struct EntityReference: Codable, Sendable {
    public var wrappedValue: SceneEntityRef
    public var requires: [SceneComponentRequirement]

    public init(wrappedValue: SceneEntityRef,
                requires: [SceneComponentRequirement] = []) {
        self.wrappedValue = wrappedValue
        self.requires = requires
    }

    public init(requires: [SceneComponentRequirement] = []) {
        self.init(wrappedValue: .capabilityPlaceholder, requires: requires)
    }

    public init(from decoder: Decoder) throws {
        wrappedValue = try SceneEntityRef(from: decoder)
        requires = []
    }

    public func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
}

extension EntityReference: AnyDeclaredCapabilityField {
    fileprivate var declaredSchema: JSONSchema {
        var schema = SceneEntityRef.capabilitySchema
        if !requires.isEmpty {
            schema.description = "\(schema.description ?? "Entity reference.") Required components: "
                + requires.map(\.rawValue).sorted().joined(separator: ", ") + "."
        }
        return schema
    }
    fileprivate var isOptional: Bool { false }
}

/// A no-second-schema input declaration. Every stored input field must use one
/// of the field wrappers above. An unwrapped field becomes an open schema node,
/// causing write-capability registration to fail closed.
public protocol DeclaredCapabilityInput: GuavaCapabilityInput, CapabilitySchemaValue {
    init()
}

public extension DeclaredCapabilityInput {
    static var inputSchema: JSONSchema {
        var properties: [String: JSONSchema] = [:]
        var required: [String] = []
        for child in Mirror(reflecting: Self.init()).children {
            guard let rawLabel = child.label else { continue }
            let label = rawLabel.hasPrefix("_") ? String(rawLabel.dropFirst()) : rawLabel
            guard let field = child.value as? any AnyDeclaredCapabilityField else {
                properties[label] = .any(description: "Undeclared capability input field.")
                continue
            }
            properties[label] = field.declaredSchema
            if !field.isOptional { required.append(label) }
        }
        return .object(properties: properties,
                       required: required,
                       additionalProperties: false)
    }

    static var capabilitySchema: JSONSchema { inputSchema }
    static var capabilityPlaceholder: Self { Self.init() }
}

/// Optional wrapped properties need a missing-key decoder path. Required fields
/// intentionally use Codable's normal `decode` and still fail when absent.
public extension KeyedDecodingContainer {
    func decode<Wrapped>(_ type: AIField<Wrapped?>.Type,
                         forKey key: Key) throws -> AIField<Wrapped?>
        where Wrapped: CapabilitySchemaValue {
        try decodeIfPresent(type, forKey: key) ?? AIField(wrappedValue: nil)
    }

    func decode<Wrapped>(_ type: ValueRange<Wrapped?>.Type,
                         forKey key: Key) throws -> ValueRange<Wrapped?>
        where Wrapped: CapabilitySchemaValue {
        try decodeIfPresent(type, forKey: key) ?? ValueRange(wrappedValue: nil)
    }
}

private extension JSONSchema {
    func applying(description: String?,
                  minimum: Double?,
                  maximum: Double?,
                  minimumLength: Int? = nil,
                  maximumLength: Int? = nil,
                  pattern: String? = nil) -> JSONSchema {
        var copy = self
        if let description, !description.isEmpty {
            copy.description = CapabilityContract.sanitiseMetadata(description, maximumLength: 1_024)
        }
        if !copy.oneOf.isEmpty {
            copy.oneOf = copy.oneOf.map {
                $0.applying(description: nil,
                            minimum: minimum,
                            maximum: maximum,
                            minimumLength: minimumLength,
                            maximumLength: maximumLength,
                            pattern: pattern)
            }
            return copy
        }
        if copy.type == .array, copy.items.count == 1 {
            copy.items[0] = copy.items[0].applying(description: nil,
                                                  minimum: minimum,
                                                  maximum: maximum)
        } else if copy.type == .number || copy.type == .integer {
            copy.minimum = minimum
            copy.maximum = maximum
        } else if minimum != nil || maximum != nil {
            return .any(description: "ValueRange can only constrain numbers and numeric vectors.")
        }
        if minimumLength != nil || maximumLength != nil || pattern != nil {
            guard copy.type == .string else {
                return .any(description: "String constraints can only be applied to strings.")
            }
            copy.minimumLength = minimumLength
            copy.maximumLength = maximumLength
            copy.pattern = pattern
        }
        return copy
    }
}
