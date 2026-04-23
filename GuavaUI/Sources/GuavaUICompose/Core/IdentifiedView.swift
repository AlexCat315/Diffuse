import GuavaUIRuntime

/// Type-erased peek at `_IdentifiedView` so the reconciler can extract the
/// inner content and stable id without knowing the inner type.
public protocol _AnyIdentifiedView {
    var _content: any View { get }
    var _id: AnyHashable { get }
}

/// Wrapper produced by the `.id(_:)` modifier. Carries an explicit identity
/// alongside the wrapped content.
///
/// Reconciler behaviour (Phase 2):
/// - The wrapper is transparent for materialisation: it expands to its
///   inner content. The produced node copies `id` into `Node.key`.
/// - During reconcile, `(viewTag, key)` matches a previously identified node
///   even after sibling reorder. State stored in the node's `attachments`
///   and any nested user-view scopes anchored on it survive the reorder.
public struct _IdentifiedView<Content: View>: View, _AnyIdentifiedView {
    public typealias Body = Never
    public let content: Content
    public let id: AnyHashable

    public init(content: Content, id: AnyHashable) {
        self.content = content
        self.id = id
    }

    public var body: Never { fatalError("_IdentifiedView is materialised through ViewGraph") }

    public var _content: any View { content }
    public var _id: AnyHashable { id }
}

public extension View {
    /// Tag this view with a stable identifier. Used by the reconciler to
    /// preserve state across reorder and structural change.
    func id<ID: Hashable>(_ id: ID) -> _IdentifiedView<Self> {
        _IdentifiedView(content: self, id: AnyHashable(id))
    }
}
