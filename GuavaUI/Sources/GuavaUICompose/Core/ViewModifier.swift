import GuavaUIRuntime

/// Modifies a view by wrapping or transforming its content.
///
/// `ViewModifier` is the GuavaUI equivalent of SwiftUI's `ViewModifier`. The
/// canonical implementation is value-type (`struct`) so animation systems in
/// later phases can interpolate between modifier instances cheaply.
///
/// There are two kinds of modifier work:
/// 1. **Layout/style** — set properties on the underlying `LayoutNode` /
///    `RenderNode` directly via `apply(layout:render:)`. No new view subtree.
/// 2. **Wrapping** — return a new view from `body(content:)` that contains
///    `content` inside additional structure (e.g. `.background { ... }`).
///
/// Implement either `apply` or `body` (or both), depending on the modifier's
/// purpose. The default implementation of `body(content:)` is the content
/// itself (i.e. no wrapping).
public protocol ViewModifier {
    associatedtype Body: View

    /// Optional: write directly into the materialised node.
    /// Called by `ViewGraph` after the underlying node is created/reused.
    func apply(node: Node)

    /// Optional: wrap `content` into a new view subtree.
    /// Default: pass-through.
    @ViewBuilder func body(content: Content) -> Body

    /// The placeholder for the original view passed to `body(content:)`.
    typealias Content = _ViewModifier_Content<Self>
}

public extension ViewModifier {
    func apply(node: Node) { /* no-op by default */ }
}

public extension ViewModifier where Body == _ViewModifier_Content<Self> {
    func body(content: Content) -> _ViewModifier_Content<Self> { content }
}

/// Stand-in passed to `ViewModifier.body(content:)`; the `ViewGraph` substitutes
/// the actual wrapped content at materialisation time.
public struct _ViewModifier_Content<Modifier: ViewModifier>: View {
    public typealias Body = Never
    public var body: Never { fatalError("_ViewModifier_Content has no body") }
}

/// A view paired with a modifier — produced by `View.modifier(_:)`.
public struct ModifiedContent<Content: View, Modifier: ViewModifier>: View {
    public typealias Body = Never
    public let content: Content
    public let modifier: Modifier

    public init(content: Content, modifier: Modifier) {
        self.content = content
        self.modifier = modifier
    }

    public var body: Never { fatalError("ModifiedContent has no body") }
}

public extension View {
    func modifier<M: ViewModifier>(_ modifier: M) -> ModifiedContent<Self, M> {
        ModifiedContent(content: self, modifier: modifier)
    }
}
