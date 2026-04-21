/// A typed key for passing values implicitly down the composition tree.
///
/// `CompositionLocal` is a reference type so each declaration has stable
/// identity via `ObjectIdentifier(self)`; consumers look up a value by
/// walking the `Node` parent chain until a provider pushed for the same key
/// is found. When no provider is found, `defaultValue` is returned.
///
/// ```swift
/// public let accentColor = CompositionLocal<Color>(defaultValue: .white)
///
/// // Provider (Compose layer):
/// // SomeView().compositionLocal(accentColor, Color(r: 0, g: 0.4, b: 1))
///
/// // Consumer (Runtime layer):
/// let color = node.compositionValue(of: accentColor)
/// ```
///
/// The runtime contract is intentionally minimal: storage on `Node`, a parent
/// walk, and `defaultValue` fallback. Compose-layer ergonomics
/// (`compositionLocal(_:_:)` modifier, `ThemeReader`, etc.) live in
/// `GuavaUICompose`.
public final class CompositionLocal<Value>: @unchecked Sendable {
    private let defaultValueFactory: () -> Value

    public init(defaultValue: @escaping @autoclosure () -> Value) {
        self.defaultValueFactory = defaultValue
    }

    /// The value used when no ancestor provider is found.
    public var defaultValue: Value { defaultValueFactory() }

    /// Stable lookup key derived from this declaration's reference identity.
    public var key: ObjectIdentifier { ObjectIdentifier(self) }

    /// Backwards-compatible accessor — equivalent to `defaultValue`. Prefer
    /// `Node.compositionValue(of:)` for tree-aware lookup.
    public var currentValue: Value { defaultValueFactory() }
}
