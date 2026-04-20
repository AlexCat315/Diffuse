import Foundation
import GuavaUIRuntime

/// Materialises `View` trees into the underlying `NodeTree`, and recomposes
/// affected subtrees when `@State` writes invalidate them through `Recomposer`.
///
/// Lifecycle:
/// 1. `install(root:)` builds the initial tree and wires state observers.
/// 2. State write → `Recomposer.invalidate(scopeID:body:)` queues the scope.
/// 3. `recomposer.commitAll()` (driven by the platform host each frame) re-runs
///    each queued scope's body, clears its prior nodes, and re-materialises.
///
/// Diff strategy (Phase 6.2):
/// - Each user-defined `View` materialises into an invisible *anchor* `Node`
///   added to its parent. The view's body fills the anchor's children.
/// - On recompose: anchor.children are removed and re-built from scratch.
///   No structural diff yet — Phase 7 will optimise long lists.
/// - Anchors keep sibling positions stable; only the affected scope rebuilds.
public final class ViewGraph {

    public let tree: NodeTree
    public let recomposer: Recomposer

    /// Active user-view scopes keyed by their anchor node identity.
    /// Strong reference keeps the rebuild closure alive while the anchor lives.
    private var scopes: [ObjectIdentifier: ViewScope] = [:]

    public init(tree: NodeTree, recomposer: Recomposer) {
        self.tree = tree
        self.recomposer = recomposer
    }

    // MARK: - Install

    /// Build the initial node tree from `root` and assign it to `tree.root`.
    public func install<V: View>(root: V) {
        let rootNode = Node()
        tree.root = rootNode
        _ = materialise(root, into: rootNode)
    }

    // MARK: - Materialise

    /// Materialise `view` into `parent` and return the top-level nodes added.
    /// Public so primitive/modifier helpers can recurse through us.
    public func materialise(_ view: any View, into parent: Node) -> [Node] {
        // 1. Empty
        if view is EmptyView { return [] }

        // 2. Primitive (Text / Box / Row / ...)
        if let prim = view as? any _PrimitiveView {
            return materialisePrimitive(prim, into: parent)
        }

        // 3. ModifiedContent — forward to the type-erased helper.
        if let mod = view as? any _AnyModifiedContent {
            return mod._materialiseInto(parent: parent, graph: self)
        }

        // 4. Structural (TupleView / Conditional / Optional / Array)
        if let st = view as? any _StructuralView {
            return st._expanded.flatMap { materialise($0, into: parent) }
        }

        // 5. User-defined View — install a scope.
        return materialiseUserView(view, into: parent)
    }

    // MARK: - Primitives

    private func materialisePrimitive(_ view: any _PrimitiveView,
                                      into parent: Node) -> [Node] {
        let node = view._makeNode()
        view._updateNode(node)
        parent.addChild(node)
        for child in view._children {
            _ = materialise(child, into: node)
        }
        return [node]
    }

    // MARK: - User views (scopes)

    private func materialiseUserView(_ view: any View, into parent: Node) -> [Node] {
        let anchor = Node()
        anchor.isHitTestable = false  // anchors are pass-through.
        parent.addChild(anchor)

        let scope = ViewScope(graph: self, anchor: anchor, view: view)
        scopes[ObjectIdentifier(anchor)] = scope
        scope.install()
        return [anchor]
    }

    // MARK: - Internal

    func dropScope(for anchor: Node) {
        scopes.removeValue(forKey: ObjectIdentifier(anchor))
    }
}

// MARK: - ViewScope

/// One user-view instantiation. Owns an anchor `Node`, the view value, and the
/// bookkeeping needed to recompose into the same anchor.
final class ViewScope {

    weak var graph: ViewGraph?
    weak var anchor: Node?
    var view: any View

    init(graph: ViewGraph, anchor: Node, view: any View) {
        self.graph = graph
        self.anchor = anchor
        self.view = view
    }

    /// Wire state observers and materialise the body for the first time.
    func install() {
        wireDynamicProperties()
        materialiseBody()
    }

    /// Discover `@State` / other `DynamicProperty` members and route their
    /// `onChange` into the recomposer.
    private func wireDynamicProperties() {
        let mirror = Mirror(reflecting: view)
        guard let graph = graph, let anchor = anchor else { return }
        let scopeID = ObjectIdentifier(anchor)

        for child in mirror.children {
            // `@State` adds a `_storage` member to the State struct; we identify
            // a `State<T>` by trying a bridging via its `_setOnChange` method.
            // Because State is generic we can't pattern match cleanly — call
            // through the runtime helper.
            if let stateBox = child.value as? _StateErased {
                stateBox._wire(invalidate: { [weak self, weak graph] in
                    guard let self, let graph else { return }
                    graph.recomposer.invalidate(scopeID: scopeID) { [weak self] in
                        self?.recompose()
                    }
                })
            }
        }
    }

    /// Re-evaluate body, clear old children, materialise fresh ones.
    func recompose() {
        guard let anchor = anchor else { return }
        // Remove prior subtree.
        for child in anchor.children { child.removeFromParent() }
        materialiseBody()
    }

    private func materialiseBody() {
        guard let graph = graph, let anchor = anchor else { return }
        // `view.body` is `some View`; expose via existential.
        let body = anyBody(of: view)
        _ = graph.materialise(body, into: anchor)
    }

    /// Read `view.body` through an existential boundary. We don't care about
    /// the concrete `Body` type — only that it's a `View`.
    private func anyBody(of view: any View) -> any View {
        func extract<V: View>(_ v: V) -> any View { v.body }
        return extract(view)
    }
}

// MARK: - State erasure shim

/// Existential helper so `ViewScope` can wire state observers without knowing
/// the concrete value type of every `@State`.
public protocol _StateErased {
    func _wire(invalidate: @escaping () -> Void)
}

extension State: _StateErased {
    public func _wire(invalidate: @escaping () -> Void) {
        _setOnChange(invalidate)
    }
}
