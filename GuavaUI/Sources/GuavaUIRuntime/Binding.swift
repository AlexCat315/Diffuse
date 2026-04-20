/// A bidirectional reference to a mutable value owned elsewhere.
///
/// Use `$state` on a `@State` property to obtain a `Binding`:
/// ```swift
/// struct Toggle: View {
///     @Binding var isOn: Bool
///     var body: some View {
///         Button(isOn ? "ON" : "OFF") { isOn.toggle() }
///     }
/// }
/// ```
public struct Binding<Value>: @unchecked Sendable {

    private let _get: () -> Value
    private let _set: (Value) -> Void

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        _get = get
        _set = set
    }

    public var wrappedValue: Value {
        get { _get() }
        nonmutating set { _set(newValue) }
    }

    /// A `Binding` that always reads `value` and silently drops writes.
    /// Useful for previews and tests.
    public static func constant(_ value: Value) -> Binding<Value> {
        Binding(get: { value }, set: { _ in })
    }
}
