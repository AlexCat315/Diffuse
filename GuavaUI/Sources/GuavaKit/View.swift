// The declarative layer. A `View` is a lightweight value describing UI; the
// `ViewGraph` reconciles it into the retained `UINode` tree from Stages 1–4.
//
// Two kinds of view:
//   * **User views** have a `body` (the SwiftUI-style `var body: some View`).
//     They are transparent — they contribute whatever their body produces — and
//     each gets a persistent *scope* that owns its `@State`.
//   * **Primitive views** (`_PrimitiveView`) materialize directly into a
//     `UINode` and may carry child views.

public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
}

/// Terminal of the `Body` recursion — primitive views have `Body == Never`.
extension Never: View {
    public var body: Never { fatalError("Never has no body") }
}

/// A view that maps straight onto a `UINode`.
public protocol _PrimitiveView: View where Body == Never {
    func makeNode() -> UINode
    func updateNode(_ node: UINode)
    var childViews: [any View] { get }
}

public extension _PrimitiveView {
    var body: Never { fatalError("\(type(of: self)) is primitive and has no body") }
    var childViews: [any View] { [] }
}

/// Produces nothing.
public struct EmptyView: View, _StructuralView {
    public init() {}
    public var body: Never { fatalError("EmptyView has no body") }
    var _expanded: [any View] { [] }
}

/// Structural views (TupleView / Optional / Conditional / EmptyView) are
/// transparent: they expand into the parent's child list rather than producing
/// a node of their own. The reconciler flattens them away.
protocol _StructuralView {
    var _expanded: [any View] { get }
}
