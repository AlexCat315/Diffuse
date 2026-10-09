public enum ComponentWriteMode: String, Codable, Sendable {
    case replace, merge
}

public enum ComponentEditError: Error, Sendable, Equatable {
    case unknownType(String)
    case missingComponent(String)
    case incompatibleComponent(String)
    case invalidValue(String)
    case invalidArrayIndex(String)
}

public extension ComponentValue {
    var isFiniteJSON: Bool {
        switch self {
        case let .number(value): value.isFinite
        case let .array(values): values.allSatisfy(\.isFiniteJSON)
        case let .object(values): values.values.allSatisfy(\.isFiniteJSON)
        default: true
        }
    }

    /// Objects merge recursively; arrays replace as a whole. An object keyed by
    /// existing array indices edits those elements without dropping sibling shapes.
    func merging(_ changes: ComponentValue) throws -> ComponentValue {
        guard case let .object(fields) = changes else { return changes }
        if case var .array(values) = self {
            for (key, value) in fields {
                guard let index = Int(key), values.indices.contains(index) else {
                    throw ComponentEditError.invalidArrayIndex(key)
                }
                values[index] = try values[index].merging(value)
            }
            return .array(values)
        }
        guard case var .object(values) = self else { return changes }
        for (key, value) in fields {
            values[key] = try (values[key] ?? .null).merging(value)
        }
        return .object(values)
    }

    /// Tests the supplied fields after decoding. Whole documents use equality;
    /// merged objects and array-index edits only assert their addressed fields.
    func containsFields(_ expected: ComponentValue) -> Bool {
        if case let .number(actual) = self, case let .number(value) = expected {
            return actual == value || (actual.isFinite && value.isFinite
                && abs(actual - value) <= max(1, abs(value)) * 0.000001)
        }
        guard case let .object(fields) = expected else { return self == expected }
        switch self {
        case let .object(values):
            return fields.allSatisfy { key, value in
                (values[key] ?? .null).containsFields(value)
            }
        case let .array(values):
            return fields.allSatisfy { key, value in
                guard let index = Int(key), values.indices.contains(index) else { return false }
                return values[index].containsFields(value)
            }
        default: return false
        }
    }
}
