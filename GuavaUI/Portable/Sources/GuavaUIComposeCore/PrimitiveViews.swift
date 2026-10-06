/// A view that displays nothing and produces no nodes.
public struct EmptyView: View {
    public typealias Body = Never
    public init() {}
    public var body: Never { fatalError("EmptyView has no body") }
}

/// Variadic view container produced by `@ViewBuilder` for 2+ children.
///
/// `T` is a tuple of `View`s. The `ViewGraph` knows how to flatten it into
/// individual node children at materialisation time.
public struct TupleView<T>: View {
    public typealias Body = Never
    public let value: T

    public init(_ value: T) {
        self.value = value
    }

    public var body: Never { fatalError("TupleView has no body") }
}

/// Either-branch view produced by `@ViewBuilder` for `if/else`.
public enum _ConditionalContent<TrueContent: View, FalseContent: View>: View {
    public typealias Body = Never
    case first(TrueContent)
    case second(FalseContent)

    public var body: Never { fatalError("_ConditionalContent has no body") }
}

/// Optional view produced by `@ViewBuilder` for a bare `if` (no `else`).
extension Optional: View where Wrapped: View {
    public typealias Body = Never
    public var body: Never { fatalError("Optional<View> has no body") }
}
