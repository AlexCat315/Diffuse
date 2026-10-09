public extension ComponentValue {
    var numericValue: Double? {
        switch self {
        case let .number(value): value
        case let .signedInteger(value): Double(value)
        case let .unsignedInteger(value): Double(value)
        default: nil
        }
    }

    func value(at path: [String]) -> ComponentValue? {
        guard let first = path.first else { return self }
        switch self {
        case let .object(values): return values[first]?.value(at: Array(path.dropFirst()))
        case let .array(values):
            guard let index = Int(first), values.indices.contains(index) else { return nil }
            return values[index].value(at: Array(path.dropFirst()))
        default: return nil
        }
    }

    static func fieldPatch(_ value: ComponentValue, at path: [String]) -> ComponentValue {
        path.reversed().reduce(value) { .object([$1: $0]) }
    }
}
