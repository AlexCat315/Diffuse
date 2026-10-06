/// Result builder used to compose views inside container bodies.
///
/// Supports:
/// - 0..N child views (variadic via `each` parameter pack)
/// - `if`           → `Optional<View>`
/// - `if/else`      → `_ConditionalContent`
/// - `for-in`       → `[View]` via `buildArray`
@resultBuilder
public enum ViewBuilder {

    // MARK: - Block (variadic via parameter packs)

    public static func buildBlock() -> EmptyView {
        EmptyView()
    }

    public static func buildBlock<Content: View>(_ content: Content) -> Content {
        content
    }

    public static func buildBlock<each Content: View>(
        _ content: repeat each Content
    ) -> TupleView<(repeat each Content)> {
        TupleView((repeat each content))
    }

    // MARK: - if

    public static func buildIf<Content: View>(_ content: Content?) -> Content? {
        content
    }

    public static func buildOptional<Content: View>(_ content: Content?) -> Content? {
        content
    }

    // MARK: - if / else

    public static func buildEither<TrueContent: View, FalseContent: View>(
        first: TrueContent
    ) -> _ConditionalContent<TrueContent, FalseContent> {
        .first(first)
    }

    public static func buildEither<TrueContent: View, FalseContent: View>(
        second: FalseContent
    ) -> _ConditionalContent<TrueContent, FalseContent> {
        .second(second)
    }

    // MARK: - for-in

    public static func buildArray<Content: View>(_ components: [Content]) -> [Content] {
        components
    }
}

/// Arrays of views are themselves views — used by `buildArray`.
extension Array: View where Element: View {
    public typealias Body = Never
    public var body: Never { fatalError("Array<View> has no body") }
}
