/// A typed key for passing values implicitly down the composition tree.
///
/// Phase 1 stub — `currentValue` always returns `defaultValue`.
/// Full scope-stack lookup is wired in Phase 6 when the composition tree exists.
///
/// ```swift
/// let accentColor = CompositionLocal(defaultValue: Color.blue)
/// let color = accentColor.currentValue   // Blue until overridden by a provider
/// ```
public struct CompositionLocal<Value> {
    private let defaultValue: () -> Value

    public init(defaultValue: @escaping @autoclosure () -> Value) {
        self.defaultValue = defaultValue
    }

    /// The value from the nearest ancestor scope, or `defaultValue` when none exists.
    public var currentValue: Value { defaultValue() }
}
