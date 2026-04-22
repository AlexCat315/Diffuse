import Foundation
import GuavaUIRuntime

/// Materialises `View` trees into the underlying `NodeTree`, and recomposes
/// affected subtrees when `@State` writes invalidate them through `Recomposer`.
///
/// Lifecycle:
/// 1. `install(root:)` builds the initial tree and wires state observers.
/// 2. State write → `Recomposer.invalidate(scopeID:body:)` queues the scope.
/// 3. `recomposer.commitAll()` (driven by the platform host each frame) re-runs
///    each queued scope's body and reconciles the produced views against the
///    existing nodes in place.
///
/// Reconcile strategy (Phase 6.6):
/// - Each Node carries a `viewTag` recording the type of view that produced
///   it (`String(reflecting: type(of: view))`).
/// - On recompose, ViewScope walks new and existing children of the anchor
///   in lockstep. As long as the tags match at the same index, the existing
///   Node is reused and its primitive's `_updateNode` is re-run; primitive
///   state stored in `Node.attachments` therefore survives the recompose.
/// - When a tag mismatches at index `i`, every old child from `i` onwards is
///   torn down and the new tail is materialised fresh. This is a deliberately
///   coarse algorithm — index-stable trees (the @State common case) reuse
///   100% of nodes; structural changes invalidate only the changing tail.
/// - User views as children always rebuild their scope on the parent's
///   recompose; preserving nested `@State` across parent recomposes is a
///   Phase 7 task.
public final class ViewGraph {

    public let tree: NodeTree
    public let recomposer: Recomposer

    /// Root layout node mirroring `tree.root`. All layout nodes from primitive
    /// views become its descendants (skipping anchor nodes that have no layout
    /// representation).
    public let layoutRoot: LayoutNode

    /// `Node` → paired `LayoutNode`. Anchor nodes are absent from this map.
    internal var layoutOf: [ObjectIdentifier: LayoutNode] = [:]

    /// Active user-view scopes keyed by their anchor node identity.
    /// Strong reference keeps the rebuild closure alive while the anchor lives.
    internal var scopes: [ObjectIdentifier: ViewScope] = [:]

    private var lastLayoutSize: (width: Float, height: Float)?

    public init(tree: NodeTree, recomposer: Recomposer) {
        self.tree = tree
        self.recomposer = recomposer
        self.layoutRoot = LayoutNode()
    }

    // MARK: - Install

    /// Build the initial node tree from `root` and assign it to `tree.root`.
    public func install<V: View>(root: V) {
        let rootNode = Node()
        tree.root = rootNode
        layoutOf[ObjectIdentifier(rootNode)] = layoutRoot
        _ = materialise(root, into: rootNode, layoutParent: layoutRoot)
    }

    // MARK: - Layout

    /// Run a Yoga layout pass over the layout tree and write the resulting
    /// frames back to the corresponding `Node`s.
    ///
    /// Call once per frame after `recomposer.commitAll()` and before draw.
    public func computeLayout(width: Float, height: Float) {
        lastLayoutSize = (width, height)
        layoutRoot.calculateLayout(availableWidth: width, availableHeight: height)
        guard let root = tree.root else { return }
        writeLayoutBack(node: root)
    }

    /// Run layout only when Yoga says some layout node is dirty or the root
    /// viewport size changed since the last pass.
    @discardableResult
    public func computeLayoutIfNeeded(width: Float, height: Float) -> Bool {
        guard layoutNeedsUpdate(width: width, height: height) else {
            return false
        }
        computeLayout(width: width, height: height)
        return true
    }

    public func layoutNeedsUpdate(width: Float, height: Float) -> Bool {
        guard let lastLayoutSize else {
            return true
        }
        if lastLayoutSize.width != width || lastLayoutSize.height != height {
            return true
        }
        return layoutRoot.subtreeIsDirty
    }

    private func writeLayoutBack(node: Node) {
        if let ln = layoutOf[ObjectIdentifier(node)] {
            node.frame = ln.frame
        }
        for child in node.children { writeLayoutBack(node: child) }
    }

    /// Layout node paired with `node`, if any.
    public func layoutNode(for node: Node) -> LayoutNode? {
        layoutOf[ObjectIdentifier(node)]
    }

    // MARK: - Reconcile entry points

    /// Tag stored in `Node.viewTag` for reuse decisions during recompose.
    /// Two views match iff their tags compare equal.
    static func slotTag(_ view: any View) -> String {
        String(reflecting: type(of: view))
    }

    /// Flatten structural views (Tuple / Conditional / Optional / Array) and
    /// strip `EmptyView` so the result contains exactly one entry per Node
    /// slot the parent will end up holding.
    static func flattenSlots(_ views: [any View]) -> [any View] {
        var out: [any View] = []
        for v in views {
            if v is EmptyView { continue }
            if let any = v as? AnyView {
                out.append(contentsOf: flattenSlots([any.storage]))
            } else if let s = v as? any _StructuralView {
                out.append(contentsOf: flattenSlots(s._expanded))
            } else {
                out.append(v)
            }
        }
        return out
    }

    /// Reconcile `parent.children` against the slot list produced by `newViews`.
    /// Reuses every leading child whose `viewTag` matches the new view at the
    /// same index, then either tears down or appends as the lists diverge.
    func reconcileChildren(parent: Node,
                           layoutParent: LayoutNode?,
                           newViews: [any View]) {
        let flat = ViewGraph.flattenSlots(newViews)
        let oldChildren = parent.children

        // 1. Reuse the longest matching prefix.
        var prefix = 0
        let prefixLimit = min(oldChildren.count, flat.count)
        while prefix < prefixLimit
              && oldChildren[prefix].viewTag == ViewGraph.slotTag(flat[prefix]) {
            updateInPlace(node: oldChildren[prefix],
                          view: flat[prefix],
                          layoutParent: layoutParent)
            prefix += 1
        }

        // 2. Tear down trailing old children that no longer match.
        for j in prefix..<oldChildren.count {
            tearDown(node: oldChildren[j], parentLayout: layoutParent)
        }

        // 3. Append the trailing new views as fresh materialisations.
        for j in prefix..<flat.count {
            _ = materialise(flat[j], into: parent, layoutParent: layoutParent)
        }
    }

    /// Refresh the properties of an already-materialised node from `view`,
    /// then recurse into its children. Caller has already verified that
    /// `node.viewTag == slotTag(view)`.
    func updateInPlace(node: Node, view: any View, layoutParent: LayoutNode?) {
        if let any = view as? AnyView {
            updateInPlace(node: node, view: any.storage, layoutParent: layoutParent)
            return
        }

        if let prim = view as? any _PrimitiveView {
            prim._updateNode(node)
            let myLayout = layoutOf[ObjectIdentifier(node)]
            if let ln = myLayout { prim._updateLayout(ln) }
            reconcileChildren(parent: node,
                              layoutParent: myLayout ?? layoutParent,
                              newViews: prim._children(for: node))
            return
        }

        if let mod = view as? any _AnyModifiedContent {
            mod._updateInPlace(node: node, layoutParent: layoutParent, graph: self)
            return
        }

        // User view: replace the scope's view value and recompose its body.
        // Note: any `@State` storage in the new view value is discarded; the
        // existing scope keeps its previously-wired storage so state survives.
        if let scope = scopes[ObjectIdentifier(node)] {
            scope.replaceView(with: view)
            scope.recompose()
        }
    }

    /// Remove a node from the tree, drop its layout-side bookkeeping, drop
    /// any user-view scope rooted at it, and drop interaction-registry entries
    /// for the entire subtree.
    func tearDown(node: Node, parentLayout: LayoutNode?) {
        // Recursively tear down child scopes first so they unregister cleanly.
        for child in node.children {
            tearDownSubtreeBookkeeping(child, parentLayout:
                layoutOf[ObjectIdentifier(node)] ?? parentLayout)
        }
        tearDownSubtreeBookkeeping(node, parentLayout: parentLayout)
        node.removeFromParent()
    }

    /// Per-node bookkeeping cleanup, recursive.
    private func tearDownSubtreeBookkeeping(_ node: Node, parentLayout: LayoutNode?) {
        let id = ObjectIdentifier(node)
        if let myLN = layoutOf.removeValue(forKey: id) {
            parentLayout?.removeChild(myLN)
        }
        scopes.removeValue(forKey: id)
        for child in node.children {
            tearDownSubtreeBookkeeping(child,
                                       parentLayout: layoutOf[id] ?? parentLayout)
        }
    }

    // MARK: - Materialise

    /// Materialise `view` into `parent` and return the top-level nodes added.
    /// Public so primitive/modifier helpers can recurse through us.
    public func materialise(_ view: any View,
                            into parent: Node,
                            layoutParent: LayoutNode? = nil) -> [Node] {
        // 1. Empty
        if view is EmptyView { return [] }

        // 1b. AnyView — recurse straight into the erased storage.
        if let any = view as? AnyView {
            return materialise(any.storage, into: parent, layoutParent: layoutParent)
        }

        // 2. Primitive (Text / Box / Row / ...)
        if let prim = view as? any _PrimitiveView {
            return materialisePrimitive(prim, into: parent, layoutParent: layoutParent)
        }

        // 3. ModifiedContent — forward to the type-erased helper.
        if let mod = view as? any _AnyModifiedContent {
            return mod._materialiseInto(parent: parent, layoutParent: layoutParent, graph: self)
        }

        // 4. Structural (TupleView / Conditional / Optional / Array)
        if let st = view as? any _StructuralView {
            return st._expanded.flatMap {
                materialise($0, into: parent, layoutParent: layoutParent)
            }
        }

        // 5. User-defined View — install a scope.
        return materialiseUserView(view, into: parent, layoutParent: layoutParent)
    }

    // MARK: - Primitives

    private func materialisePrimitive(_ view: any _PrimitiveView,
                                      into parent: Node,
                                      layoutParent: LayoutNode?) -> [Node] {
        let node = view._makeNode()
        node.viewTag = ViewGraph.slotTag(view)
        // Build the layout node and wire both trees BEFORE `_updateNode`
        // so that `compositionValue(of:)` walks a complete parent chain
        // and `node.layoutNode` is non-nil. Primitives can therefore
        // drive frame dimensions from theme tokens directly inside
        // `_updateNode` without lazy-deferring to a closure.
        let ln = view._makeLayoutNode()
        if let ln {
            node.layoutNode = ln
            layoutOf[ObjectIdentifier(node)] = ln
            layoutParent?.addChild(ln)
        }
        parent.addChild(node)
        view._updateNode(node)

        var childLayoutParent = layoutParent
        if let ln {
            view._updateLayout(ln)
            childLayoutParent = ln
        }

        for child in view._children(for: node) {
            _ = materialise(child, into: node, layoutParent: childLayoutParent)
        }
        return [node]
    }

    // MARK: - User views (scopes)

    private func materialiseUserView(_ view: any View,
                                     into parent: Node,
                                     layoutParent: LayoutNode?) -> [Node] {
        let anchor = Node()
        anchor.isHitTestable = false  // anchors are pass-through.
        anchor.viewTag = ViewGraph.slotTag(view)
        parent.addChild(anchor)
        // Anchor nodes do NOT get a LayoutNode — they're transparent for layout.

        let scope = ViewScope(graph: self, anchor: anchor, view: view,
                              layoutParent: layoutParent)
        scopes[ObjectIdentifier(anchor)] = scope
        scope.install()
        return [anchor]
    }

    // MARK: - Internal

    func dropScope(for anchor: Node) {
        scopes.removeValue(forKey: ObjectIdentifier(anchor))
    }

    /// Remove a node's layout node from the layout tree (via `parent`'s removeChild)
    /// and forget it. Caller passes the LayoutNode parent because LayoutNode has
    /// no `parent` back-reference. Recurses through the Node tree.
    func forgetSubtreeLayout(_ node: Node, parentLayout: LayoutNode?) {
        let myLN = layoutOf.removeValue(forKey: ObjectIdentifier(node))
        if let myLN, let parentLayout {
            parentLayout.removeChild(myLN)
        }
        let nextParent = myLN ?? parentLayout
        for child in node.children { forgetSubtreeLayout(child, parentLayout: nextParent) }
    }
}

// MARK: - ViewScope

/// One user-view instantiation. Owns an anchor `Node`, the view value, and the
/// bookkeeping needed to recompose into the same anchor.
final class ViewScope {

    weak var graph: ViewGraph?
    weak var anchor: Node?
    var view: any View
    weak var layoutParent: LayoutNode?

    init(graph: ViewGraph, anchor: Node, view: any View, layoutParent: LayoutNode?) {
        self.graph = graph
        self.anchor = anchor
        self.view = view
        self.layoutParent = layoutParent
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
                    // Capture the animation context at write time. The
                    // recomposer stores the animation alongside the body and
                    // re-establishes it before invoking the body in
                    // `commitAll`.
                    let capturedAnim = ActiveAnimationContext.current
                    graph.recomposer.invalidate(
                        scopeID: scopeID,
                        animation: capturedAnim
                    ) { [weak self] in
                        self?.recompose()
                    }
                })
            }
        }
    }

    /// Re-evaluate body and reconcile against the existing anchor children.
    /// Nodes whose `viewTag` matches the new body at the same index are
    /// preserved (along with anything in `Node.attachments`).
    func recompose() {
        guard let anchor = anchor, let graph = graph else { return }
        let body = anyBody(of: view)
        graph.reconcileChildren(parent: anchor,
                                layoutParent: layoutParent,
                                newViews: [body])
    }

    /// Swap in a new view value while keeping previously-wired `@State`
    /// values intact. Walks the Mirrors of both old and new in parallel and
    /// copies each `_StateErased` storage value from old → new.
    func replaceView(with newView: any View) {
        let oldMirror = Mirror(reflecting: view)
        let newMirror = Mirror(reflecting: newView)
        let oldChildren = Array(oldMirror.children)
        for newChild in newMirror.children {
            guard let label = newChild.label,
                  let newBox = newChild.value as? _StateErased else { continue }
            if let match = oldChildren.first(where: { $0.label == label }),
               let oldBox = match.value as? _StateErased {
                newBox._copyValue(from: oldBox)
            }
        }
        view = newView
        // Re-wire onChange against the new storage references so future writes
        // still invalidate this scope.
        wireDynamicProperties()
    }

    private func materialiseBody() {
        guard let graph = graph, let anchor = anchor else { return }
        let body = anyBody(of: view)
        _ = graph.materialise(body, into: anchor, layoutParent: layoutParent)
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
    /// Copy the runtime value out of `other` into self's backing storage.
    /// No-op if the concrete value types do not match.
    func _copyValue(from other: _StateErased)
}

extension State: _StateErased {
    public func _wire(invalidate: @escaping () -> Void) {
        _setOnChange(invalidate)
    }

    public func _copyValue(from other: _StateErased) {
        guard let typed = other as? State<Value> else { return }
        _copyRuntimeValue(from: typed)
    }
}
