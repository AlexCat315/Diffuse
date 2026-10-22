import Swift

/// A JSON value. Embedded Swift has no `Codable` or Foundation, so plugins
/// read requests and write results through this type. Numbers are integers:
/// fractions are truncated when parsed.
public enum JSON {
    case null
    case bool(Bool)
    case number(Int64)
    case string(String)
    case array([JSON])
    case object(JSONObject)
    /// Text already encoded as JSON, such as a `JSONWriter`'s output. It is
    /// written as is; parsing never produces it.
    case raw(String)

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var int: Int? {
        if case let .number(value) = self, let result = Int(exactly: value) { return result }
        return nil
    }

    public var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var array: [JSON]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var object: JSONObject? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The member named `key` of an object; nil for anything else.
    public subscript(key: String) -> JSON? { object?[key] }
}

/// Object members in insertion order, so output is deterministic.
public struct JSONObject {
    public private(set) var members: [(key: String, value: JSON)] = []

    public init() {}

    public subscript(key: String) -> JSON? {
        get {
            for member in members where member.key == key { return member.value }
            return nil
        }
        set {
            let index = members.firstIndex { $0.key == key }
            switch (index, newValue) {
            case let (index?, value?): members[index].value = value
            case let (index?, nil): members.remove(at: index)
            case let (nil, value?): members.append((key, value))
            case (nil, nil): break
            }
        }
    }
}

extension JSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) {
        members.reserveCapacity(elements.count)
        for (key, value) in elements { self[key] = value }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Int64(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var object = JSONObject()
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }

    public init(_ value: Int) { self = .number(Int64(value)) }
    public init(_ value: String?) { self = value.map(JSON.string) ?? .null }
    public init(_ values: [String]) { self = .array(values.map(JSON.string)) }
}
