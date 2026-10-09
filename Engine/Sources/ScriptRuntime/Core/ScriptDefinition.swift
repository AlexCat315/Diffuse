import CoreFoundation
import Foundation
import SIMDCompat

/// The authoring contract of a behavior. It contains no live script instance.
/// The Editor and Player use the same defaults; scene bindings store overrides.
public struct ScriptDefinition: Sendable, Equatable, Codable {
    public var properties: [ScriptProperty]

    public init(properties: [ScriptProperty] = []) {
        self.properties = properties
    }

    public func defaultParameters(overriding json: String = "{}") -> [String: Any] {
        var values: [String: Any] = [:]
        for property in properties { values[property.key] = property.defaultValue.jsonValue }
        for (key, value) in Self.decodeParameters(json) { values[key] = value }
        return values
    }

    public func resolvedParameters(defaultsJSON: String = "{}", overridesJSON: String = "{}") -> [String: Any] {
        var values = defaultParameters(overriding: defaultsJSON)
        for property in properties {
            if let value = values[property.key], !property.accepts(value) {
                values[property.key] = property.defaultValue.jsonValue
            }
        }
        for (key, value) in Self.decodeParameters(overridesJSON) {
            if let property = properties.first(where: { $0.key == key }), !property.accepts(value) { continue }
            values[key] = value
        }
        return values
    }

    public func defaultParametersJSON(overriding json: String = "{}") -> String {
        Self.encodeParameters(defaultParameters(overriding: json)) ?? "{}"
    }

    /// Checks meaning as well as JSON syntax. Unknown keys are retained for
    /// compatibility, but must not silently look like supported properties.
    public func parameterIssues(in json: String) -> [ScriptParameterIssue] {
        guard let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [.invalidDocument]
        }
        guard !properties.isEmpty else { return [] }
        let known = Set(properties.map(\.key))
        var issues = values.keys.filter { !known.contains($0) }.sorted().map(ScriptParameterIssue.unknown)
        for property in properties {
            if let value = values[property.key], !property.accepts(value) {
                issues.append(.invalid(property.key))
            }
        }
        return issues
    }

    public static func decodeParameters(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return values
    }

    public static func encodeParameters(_ values: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public enum ScriptParameterIssue: Sendable, Equatable {
    case invalidDocument
    case unknown(String)
    case invalid(String)
}

public enum ScriptPropertyValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case integer(Int)
    case boolean(Bool)
    case vector3(SIMD3<Float>)
    case entity(UInt64)

    public var jsonValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .integer(let value): return value
        case .boolean(let value): return value
        case .vector3(let value): return [value.x, value.y, value.z]
        case .entity(let value): return value
        }
    }

    public func decoding(_ value: Any) -> ScriptPropertyValue? {
        switch self {
        case .string:
            return (value as? String).map(Self.string)
        case .boolean:
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return .boolean(number.boolValue)
        case .number, .integer, .entity:
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else { return nil }
            switch self {
            case .integer: return Int(exactly: number.doubleValue).map(Self.integer)
            case .entity:
                guard number.decimalValue >= 0,
                      number.decimalValue == Decimal(number.uint64Value) else { return nil }
                return .entity(number.uint64Value)
            default: return .number(number.doubleValue)
            }
        case .vector3:
            let values: [Any]
            if let array = value as? [Any] { values = array }
            else if let object = value as? [String: Any], let x = object["x"], let y = object["y"], let z = object["z"] {
                values = [x, y, z]
            } else { return nil }
            guard values.count == 3 else { return nil }
            let numbers = values.compactMap { Self.number(0).decoding($0) }
            guard numbers.count == 3 else { return nil }
            let floats = numbers.compactMap { value -> Float? in
                guard case .number(let number) = value, Float(number).isFinite else { return nil }
                return Float(number)
            }
            guard floats.count == 3 else { return nil }
            return .vector3(SIMD3(floats[0], floats[1], floats[2]))
        }
    }
}

public struct ScriptPropertyOption: Sendable, Equatable, Codable {
    public let value: String
    public let label: String

    public init(_ value: String, label: String? = nil) {
        self.value = value
        self.label = label ?? value
    }
}

public struct ScriptProperty: Sendable, Equatable, Codable {
    public let key: String
    public let label: String
    public let group: String?
    public let help: String?
    public let defaultValue: ScriptPropertyValue
    public let minimum: Double?
    public let maximum: Double?
    public let step: Double?
    public let options: [ScriptPropertyOption]

    public init(_ key: String, label: String? = nil, group: String? = nil, help: String? = nil,
                defaultValue: ScriptPropertyValue, minimum: Double? = nil, maximum: Double? = nil,
                step: Double? = nil, options: [ScriptPropertyOption] = []) {
        self.key = key
        self.label = label ?? key
        self.group = group
        self.help = help
        self.defaultValue = defaultValue
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.options = options
    }

    public func accepts(_ value: Any) -> Bool {
        guard let decoded = defaultValue.decoding(value) else { return false }
        switch decoded {
        case .string(let value): return options.isEmpty || options.contains { $0.value == value }
        case .number(let value): return (minimum.map { value >= $0 } ?? true) && (maximum.map { value <= $0 } ?? true)
        case .integer(let value): return (minimum.map { Double(value) >= $0 } ?? true) && (maximum.map { Double(value) <= $0 } ?? true)
        default: return true
        }
    }
}
