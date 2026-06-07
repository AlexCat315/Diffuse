// Reconciles a declarative `View` tree into the retained `UINode` tree.
//
// Identity is by **path** (child indices from the root). Same path + same view
// type on the next pass ⇒ the same node and the same `@State` scope are reused;
// a path that disappears ⇒ its node subtree and scopes are torn down (releasing
// resources/capture via the Stage 1 lifecycle). This is what makes "toggle a
// dropdown closed" deterministically clean: the removed view's path is gone, so
// everything it owned is released — no modifier side-effect required.

public final class ViewGraph {
    public let context: UIContext
    public let recomposer = Recomposer()

    private let rootNode = UINode()
    private var rootView: (any View)?
    private var scopes: [ScopePath: ViewScope] = [:]

    private struct NodeKey { let path: ScopePath; let tag: String }
    private var nodeKeys: [ObjectIdentifier: NodeKey] = [:]

    public init(context: UIContext) {
        self.context = context
    }

    public var root: UINode { rootNode }

    // MARK: - Install / commit

    public func install(root view: any View) {
        rootView = view
        context.install(root: rootNode)
        reconcile()
    }

    /// Re-reconcile if any `@State` changed since last time. Returns whether it ran.
    @discardableResult
    public func commitIfNeeded() -> Bool {
        guard recomposer.hasPending else { return false }
        _ = recomposer.drain()
        reconcile()
        return true
    }

    func scopeDidInvalidate(_ scope: ViewScope) {
        recomposer.markDirty(scope.path)
    }

    private func reconcile() {
        guard let rootView else { return }
        reconcileChildren(parent: rootNode, path: .root, newViews: [rootView])
    }

    // MARK: - Reconcile one node's children

    private struct PrimSlot { let view: any _PrimitiveView; let path: ScopePath; let tag: String }

    private func reconcileChildren(parent: UINode, path: ScopePath, newViews: [any View]) {
        var slots: [PrimSlot] = []
        expand(newViews, path: path, into: &slots)
        let newPaths = Set(slots.map { $0.path })

        // Existing children by path.
        var existing: [ScopePath: UINode] = [:]
        for child in parent.children {
            if let key = nodeKeys[ObjectIdentifier(child)] { existing[key.path] = child }
        }

        // Tear down children whose path vanished.
        for child in parent.children {
            let p = nodeKeys[ObjectIdentifier(child)]?.path
            if p == nil || !newPaths.contains(p!) { teardown(child) }
        }

        // Reuse or create, in order.
        var ordered: [UINode] = []
        for slot in slots {
            if let reuse = existing[slot.path], nodeKeys[ObjectIdentifier(reuse)]?.tag == slot.tag {
                ordered.append(reuse)
            } else {
                let node = slot.view.makeNode()
                nodeKeys[ObjectIdentifier(node)] = NodeKey(path: slot.path, tag: slot.tag)
                parent.append(node)
                ordered.append(node)
            }
        }
        parent.reorderChildren(ordered)

        // Update each node and recurse into its child views.
        for (i, slot) in slots.enumerated() {
            let node = ordered[i]
            slot.view.updateNode(node)
            reconcileChildren(parent: node, path: slot.path, newViews: slot.view.childViews)
        }
    }

    /// Expand structural and user views away, leaving a flat list of the
    /// primitives that are direct children of `parent`, each with its path.
    private func expand(_ views: [any View], path: ScopePath, into out: inout [PrimSlot]) {
        for (i, view) in views.enumerated() {
            let p = path.appending(i)
            if let structural = view as? _StructuralView {
                expand(structural._expanded, path: p, into: &out)
            } else if let prim = view as? any _PrimitiveView {
                out.append(PrimSlot(view: prim, path: p, tag: String(reflecting: type(of: prim))))
            } else {
                // User view: persistent scope keyed by path; link state, run body.
                let scope = scope(for: p, view: view)
                scope.view = view
                linkState(view, scope: scope)
                expand([bodyOf(scope.view)], path: p, into: &out)
            }
        }
    }

    // MARK: - Scopes & state

    private func scope(for path: ScopePath, view: any View) -> ViewScope {
        if let s = scopes[path] { return s }
        let s = ViewScope(path: path, view: view, graph: self)
        scopes[path] = s
        return s
    }

    private func linkState(_ view: any View, scope: ViewScope) {
        var index = 0
        for child in Mirror(reflecting: view).children {
            if let property = child.value as? _StateProperty {
                property._link(scope: scope, index: index)
                index += 1
            }
        }
    }

    private func bodyOf(_ view: any View) -> any View { view.body }

    // MARK: - Teardown

    private func teardown(_ node: UINode) {
        if let key = nodeKeys[ObjectIdentifier(node)] {
            // Drop scopes living under this subtree.
            for p in scopes.keys where p.hasPrefix(key.path) { scopes[p] = nil }
        }
        dropKeys(node)
        node.removeFromParent() // → context.detach releases resources + capture
    }

    private func dropKeys(_ node: UINode) {
        for child in node.children { dropKeys(child) }
        nodeKeys[ObjectIdentifier(node)] = nil
    }
}
