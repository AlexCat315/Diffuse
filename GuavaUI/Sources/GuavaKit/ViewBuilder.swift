// Result builder for `@ViewBuilder` closures. Multiple children become a
// `TupleView`; `if` becomes `OptionalView`; `if/else` becomes `ConditionalView`.
// All three are structural (transparent) — they flatten into the parent.

@resultBuilder
public enum ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<C: View>(_ c: C) -> C { c }

    public static func buildBlock<C0: View, C1: View>(_ c0: C0, _ c1: C1) -> TupleView { TupleView([c0, c1]) }
    public static func buildBlock<C0: View, C1: View, C2: View>(_ c0: C0, _ c1: C1, _ c2: C2) -> TupleView { TupleView([c0, c1, c2]) }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3) -> TupleView { TupleView([c0, c1, c2, c3]) }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4) -> TupleView { TupleView([c0, c1, c2, c3, c4]) }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5) -> TupleView { TupleView([c0, c1, c2, c3, c4, c5]) }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6) -> TupleView { TupleView([c0, c1, c2, c3, c4, c5, c6]) }
    public static func buildBlock<C0: View, C1: View, C2: View, C3: View, C4: View, C5: View, C6: View, C7: View>(_ c0: C0, _ c1: C1, _ c2: C2, _ c3: C3, _ c4: C4, _ c5: C5, _ c6: C6, _ c7: C7) -> TupleView { TupleView([c0, c1, c2, c3, c4, c5, c6, c7]) }

    public static func buildOptional<C: View>(_ content: C?) -> OptionalView<C> {
        OptionalView(content)
    }
    public static func buildEither<T: View, F: View>(first: T) -> ConditionalView<T, F> {
        ConditionalView(.first(first))
    }
    public static func buildEither<T: View, F: View>(second: F) -> ConditionalView<T, F> {
        ConditionalView(.second(second))
    }
    public static func buildExpression<C: View>(_ expression: C) -> C { expression }
    public static func buildArray<C: View>(_ components: [C]) -> ArrayView {
        ArrayView(components.map { $0 as any View })
    }
}

/// Several children collected into one transparent view.
public struct TupleView: View, _StructuralView {
    let items: [any View]
    init(_ items: [any View]) { self.items = items }
    public var body: Never { fatalError("TupleView has no body") }
    var _expanded: [any View] { items }
}

/// A loop / array of children.
public struct ArrayView: View, _StructuralView {
    let items: [any View]
    init(_ items: [any View]) { self.items = items }
    public var body: Never { fatalError("ArrayView has no body") }
    var _expanded: [any View] { items }
}

/// `if condition { ... }` — present or absent.
public struct OptionalView<Wrapped: View>: View, _StructuralView {
    let wrapped: Wrapped?
    init(_ wrapped: Wrapped?) { self.wrapped = wrapped }
    public var body: Never { fatalError("OptionalView has no body") }
    var _expanded: [any View] { wrapped.map { [$0] } ?? [] }
}

/// `if/else` — exactly one of two branches.
public struct ConditionalView<First: View, Second: View>: View, _StructuralView {
    enum Storage { case first(First), second(Second) }
    let storage: Storage
    init(_ storage: Storage) { self.storage = storage }
    public var body: Never { fatalError("ConditionalView has no body") }
    var _expanded: [any View] {
        switch storage {
        case .first(let f): return [f]
        case .second(let s): return [s]
        }
    }
}
