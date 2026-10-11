import GuavaUIRuntime

/// Applications add design tokens without modifying GuavaUI's closed set of
/// built-in roles. Values stay typed and travel with local Theme overrides.
public protocol ThemeExtension: Sendable {
    static var defaultValue: Self { get }
}

public struct ThemeExtensions: Sendable {
    private var values: [ObjectIdentifier: any Sendable] = [:]
    public init() {}
    public subscript<Value: ThemeExtension>(_ type: Value.Type) -> Value {
        get { values[ObjectIdentifier(type)] as? Value ?? Value.defaultValue }
        set { values[ObjectIdentifier(type)] = newValue }
    }
    public mutating func remove<Value: ThemeExtension>(_ type: Value.Type) {
        values.removeValue(forKey: ObjectIdentifier(type))
    }
}
