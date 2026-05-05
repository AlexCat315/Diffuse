import Foundation
import EngineKernel
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
    public struct LayoutSnapshotEntry: Sendable, Equatable {
        public var debugName: String?
        public var layoutRole: String?
        public var semanticRole: String?
        public var frame: CGRect
        public var absoluteFrame: CGRect

        public init(debugName: String?,
                    layoutRole: String?,
                    semanticRole: String?,
                    frame: CGRect,
                    absoluteFrame: CGRect) {
            self.debugName = debugName
            self.layoutRole = layoutRole
            self.semanticRole = semanticRole
            self.frame = frame
            self.absoluteFrame = absoluteFrame
        }
    }

    public let tree: NodeTree
    public let recomposer: Recomposer

    /// Phase 3: layout tree owning the `LayoutNode` root + the text measure
    /// cache. Layout-side state migrating off `Node` lands here.
    public let layoutTree: LayoutTree

    /// Phase 4a: render-side mirror of the Node tree. Foundation for the
    /// per-layer DrawList cache landing in Phase 4b. Maintained alongside
    /// every install / reconcile / tearDown.
    public let renderTree: RenderTree

    /// Phase 5a: input-side mirror of the Node tree. Captures hit-test /
    /// focus / cursor classification per node. Phase 5b will pivot
    /// `EventDispatcher` to consume this mirror so dispatch no longer
    /// re-walks the full Node graph each event.
    public let inputScene: InputScene

    /// Root layout node mirroring `tree.root`. All layout nodes from primitive
    /// views become its descendants (skipping anchor nodes that have no layout
    /// representation).
    public var layoutRoot: LayoutNode { layoutTree.root }

    /// `Node` → paired `LayoutNode`. Anchor nodes are absent from this map.
    internal var layoutOf: [ObjectIdentifier: LayoutNode] = [:]

    /// Active user-view scopes keyed by their anchor node identity.
    /// Strong reference keeps the rebuild closure alive while the anchor lives.
    internal var scopes: [ObjectIdentifier: ViewScope] = [:]

    private var lastLayoutSize: (width: Float, height: Float)?

    public init(tree: NodeTree, recomposer: Recomposer) {
        self.tree = tree
        self.recomposer = recomposer
        self.layoutTree = LayoutTree()
        self.renderTree = RenderTree()
        self.inputScene = InputScene()
    }

    // MARK: - Install

    /// Build the initial node tree from `root` and assign it to `tree.root`.
    public func install<V: View>(root: V) {
        let rootNode = Node()
        tree.root = rootNode
        layoutOf[ObjectIdentifier(rootNode)] = layoutRoot
        _ = materialise(root, into: rootNode, layoutParent: layoutRoot)
        renderTree.install(rootNode: rootNode)
        inputScene.install(rootNode: rootNode)
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

    private func writeLayoutBack(node: Node, parentOrigin: CGPoint = .zero) {
        if let ln = layoutOf[ObjectIdentifier(node)] {
            node.frame = ln.frame
        }
        let absoluteOrigin = CGPoint(x: parentOrigin.x + node.frame.origin.x,
                                     y: parentOrigin.y + node.frame.origin.y)
        syncTextInputArea(for: node, absoluteOrigin: absoluteOrigin)
        for child in node.children {
            writeLayoutBack(node: child, parentOrigin: absoluteOrigin)
        }
    }

    private func syncTextInputArea(for node: Node, absoluteOrigin: CGPoint) {
        let previous = node.attachments[TextInputAttachmentKey.area] as? TextInputArea
        let next: TextInputArea?
        if let resolver = node.attachments[TextInputAttachmentKey.areaResolver] as? TextInputAreaResolver {
            next = resolver(node, absoluteOrigin)
        } else {
            next = nil
        }

        guard previous != next else { return }
        if let next {
            node.attachments[TextInputAttachmentKey.area] = next
        } else {
            node.attachments.removeValue(forKey: TextInputAttachmentKey.area)
        }
        inputScene.refresh(node: node)
    }

    /// Layout node paired with `node`, if any.
    public func layoutNode(for node: Node) -> LayoutNode? {
        layoutOf[ObjectIdentifier(node)]
    }

    public func layoutSnapshot() -> [LayoutSnapshotEntry] {
        guard let root = tree.root else { return [] }
        var result: [LayoutSnapshotEntry] = []
        collectLayoutSnapshot(node: root, parentOrigin: .zero, into: &result)
        return result
    }

    private func collectLayoutSnapshot(node: Node,
                                       parentOrigin: CGPoint,
                                       into result: inout [LayoutSnapshotEntry]) {
        let absoluteOrigin = CGPoint(x: parentOrigin.x + node.frame.origin.x,
                                     y: parentOrigin.y + node.frame.origin.y)
        let absoluteFrame = CGRect(origin: absoluteOrigin, size: node.frame.size)
        let debugName = node.attachments[LayoutDebugAttachmentKey.debugName] as? String
        let layoutRole = node.attachments[LayoutDebugAttachmentKey.layoutRole] as? String
        let semanticRole = node.attachments[LayoutDebugAttachmentKey.semanticRole] as? String
        if debugName != nil || layoutRole != nil || semanticRole != nil {
            result.append(LayoutSnapshotEntry(debugName: debugName,
                                              layoutRole: layoutRole,
                                              semanticRole: semanticRole,
                                              frame: node.frame,
                                              absoluteFrame: absoluteFrame))
        }
        for child in node.children {
            collectLayoutSnapshot(node: child,
                                  parentOrigin: absoluteOrigin,
                                  into: &result)
        }
    }

    // MARK: - Reconcile entry points

    /// Tag stored in `Node.viewTag` for reuse decisions during recompose.
    /// Two views match iff their tags compare equal. Strips `_IdentifiedView`
    /// and `AnyView` wrappers so the tag describes the underlying view kind.
    static func slotTag(_ view: any View) -> String {
        classify(view).tag
    }

    /// Stable identity attached to a slot via `.id(_:)`. `nil` for unkeyed
    /// slots; the reconciler then matches by `(tag, sequential position)`.
    static func slotKey(_ view: any View) -> AnyHashable? {
        classify(view).key
    }

    /// Result of unwrapping `_IdentifiedView` / `AnyView` layers around a view.
    struct SlotInfo {
        let view: any View
        let tag: String
        let key: AnyHashable?
    }

    static func classify(_ view: any View) -> SlotInfo {
        var current: any View = view
        var key: AnyHashable? = nil
        while true {
            if let identified = current as? _AnyIdentifiedView {
                // Outermost id wins — `Foo.id(a).id(b)` resolves to `b`.
                if key == nil { key = identified._id }
                current = identified._content
                continue
            }
            if let any = current as? AnyView {
                current = any.storage
                continue
            }
            break
        }
        return SlotInfo(view: view,
                        tag: String(reflecting: type(of: current)),
                        key: key)
    }

    /// Flatten structural views (Tuple / Conditional / Optional / Array) and
    /// strip `EmptyView` so the result contains exactly one entry per Node
    /// slot the parent will end up holding. `_IdentifiedView` and `AnyView`
    /// wrappers are kept intact — the reconciler reads their identity at
    /// match time via `classify`.
    static func flattenSlots(_ views: [any View]) -> [any View] {
        var out: [any View] = []
        for v in views {
            if v is EmptyView { continue }
            if let any = v as? AnyView {
                out.append(contentsOf: flattenSlots([any.storage]))
            } else if let s = v as? any _StructuralView {
                out.append(contentsOf: flattenSlots(s._expanded))
            } else {
                // _IdentifiedView is preserved as a slot so the reconciler
                // can read `_id` during matching.
                out.append(v)
            }
        }
        return out
    }

    /// Reconcile `parent.children` against the slot list produced by `newViews`.
    ///
    /// Matching algorithm (Phase 2):
    /// 1. For each new entry compute `(tag, key)` via `classify`.
    /// 2. Old children with a `key` build a keyed lookup table; old children
    ///    without one queue per `viewTag` in original order.
    /// 3. Each new entry first tries the keyed table, then falls back to its
    ///    type queue. Otherwise it materialises fresh.
    /// 4. Old children that no other entry claimed are torn down.
    /// 5. `parent.children` and the matching `LayoutNode` siblings are
    ///    reordered to match the new sequence so reused nodes that moved
    ///    keep their state but render in the new position.
    func reconcileChildren(parent: Node,
                           layoutParent: LayoutNode?,
                           newViews: [any View]) {
        let flat = ViewGraph.flattenSlots(newViews)
        let entries = flat.map { ViewGraph.classify($0) }
        let oldChildren = parent.children

        // Build matching tables.
        var keyedOld: [KeyedSlot: Node] = [:]
        var unkeyedQueues: [String: [Node]] = [:]
        for child in oldChildren {
            if let key = child.key, let tag = child.viewTag {
                keyedOld[KeyedSlot(tag: tag, key: key)] = child
            } else if let tag = child.viewTag {
                unkeyedQueues[tag, default: []].append(child)
            } else {
                // No tag — leave unmatchable (will be torn down).
            }
        }

        // Decide an action per new entry: reuse an existing node or create one.
        enum Action {
            case reuse(Node)
            case create
        }
        var actions: [Action] = []
        actions.reserveCapacity(entries.count)
        var matchedOldIDs = Set<ObjectIdentifier>()

        // First pass: keyed matches consume their slot.
        for entry in entries {
            if let key = entry.key,
               let match = keyedOld[KeyedSlot(tag: entry.tag, key: key)] {
                matchedOldIDs.insert(ObjectIdentifier(match))
                actions.append(.reuse(match))
            } else {
                actions.append(.create) // tentative; second pass refines
            }
        }

        // Second pass: unkeyed entries pull from their per-tag queue.
        for (index, entry) in entries.enumerated() {
            guard case .create = actions[index], entry.key == nil else { continue }
            guard var queue = unkeyedQueues[entry.tag], !queue.isEmpty else { continue }
            var picked: Node? = nil
            while !queue.isEmpty {
                let candidate = queue.removeFirst()
                if !matchedOldIDs.contains(ObjectIdentifier(candidate)) {
                    matchedOldIDs.insert(ObjectIdentifier(candidate))
                    picked = candidate
                    break
                }
            }
            unkeyedQueues[entry.tag] = queue
            if let picked {
                actions[index] = .reuse(picked)
            }
        }

        // Tear down old children no entry claimed.
        for child in oldChildren where !matchedOldIDs.contains(ObjectIdentifier(child)) {
            tearDown(node: child, parentLayout: layoutParent)
        }

        // Materialise fresh entries — these append to parent.children and to
        // layoutParent. We capture the resolved Node per entry to drive the
        // reorder step below.
        var resolvedNodes: [Node?] = Array(repeating: nil, count: entries.count)
        for (i, action) in actions.enumerated() {
            switch action {
            case .reuse(let node):
                resolvedNodes[i] = node
            case .create:
                let made = materialise(entries[i].view,
                                       into: parent,
                                       layoutParent: layoutParent)
                // Stamp the explicit key so the next reconcile can match it.
                for n in made { n.key = entries[i].key }
                resolvedNodes[i] = made.first
            }
        }

        // Reorder parent.children so the final sequence matches `entries`.
        // Some entries may have produced no node (EmptyView post-strip would
        // have been filtered earlier; defensive otherwise) — skip those.
        let orderedNodes = resolvedNodes.compactMap { $0 }
        if orderedNodes.count == parent.children.count {
            parent.reorderChildren(orderedNodes)
        }

        // Reorder layout siblings to match. Anchor nodes (user-view scopes,
        // scope-applying modifiers) carry no LayoutNode and are simply absent
        // from this subset; their relative order in `layoutParent.children`
        // is unaffected because they were never there.
        if let layoutParent {
            let orderedLayouts = orderedNodes.compactMap {
                layoutOf[ObjectIdentifier($0)]
            }
            if orderedLayouts.count == layoutParent.children.count {
                layoutParent.reorderChildren(orderedLayouts)
            }
        }

        // Finally, refresh reused nodes in place. Recursing here would have
        // walked into stale children before reorder, so we run it after the
        // sibling order has been settled.
        for (i, action) in actions.enumerated() {
            if case .reuse(let node) = action {
                node.key = entries[i].key
                updateInPlace(node: node,
                              view: entries[i].view,
                              layoutParent: layoutParent)
            }
        }

        // Phase 4a: keep the RenderTree mirror in sync with the new child list.
        renderTree.reconcileChildren(of: parent)
        // Phase 5a: keep the InputScene mirror in sync as well.
        inputScene.reconcileChildren(of: parent)
    }

    /// Refresh the properties of an already-materialised node from `view`,
    /// then recurse into its children. Caller has already verified that
    /// `node.viewTag == slotTag(view)`.
    func updateInPlace(node: Node, view: any View, layoutParent: LayoutNode?) {
        if let identified = view as? _AnyIdentifiedView {
            node.key = identified._id
            updateInPlace(node: node, view: identified._content, layoutParent: layoutParent)
            return
        }
        if let any = view as? AnyView {
            updateInPlace(node: node, view: any.storage, layoutParent: layoutParent)
            return
        }

        if let prim = view as? any _PrimitiveView {
            prim._updateNode(node)
            // Phase 5a: re-read input classification after primitive may
            // have toggled isHitTestable / isFocusable / cursor.
            inputScene.refresh(node: node)
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
        // Phase 4a: drop RenderObject mirror BEFORE removing from parent so
        // we still know the parent linkage.
        renderTree.tearDown(node: node)
        // Phase 5a: drop InputNode mirror as well.
        inputScene.tearDown(node: node)
        node.removeFromParent()
    }

    /// Per-node bookkeeping cleanup, recursive.
    private func tearDownSubtreeBookkeeping(_ node: Node, parentLayout: LayoutNode?) {
        let id = ObjectIdentifier(node)
        if let myLN = layoutOf.removeValue(forKey: id) {
            parentLayout?.removeChild(myLN)
        }
        if scopes.removeValue(forKey: id) != nil {
            ObservableStateTracking.removeScope(id: id)
        }
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

        // 1a. Identified — unwrap, materialise inner, then stamp the key on
        //     each produced top-level node so the next reconcile can reuse
        //     by `(tag, key)`.
        if let identified = view as? _AnyIdentifiedView {
            let nodes = materialise(identified._content,
                                    into: parent,
                                    layoutParent: layoutParent)
            for n in nodes { n.key = identified._id }
            return nodes
        }

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
        let body = trackedBody(scopeID: ObjectIdentifier(anchor))
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
        let body = trackedBody(scopeID: ObjectIdentifier(anchor))
        _ = graph.materialise(body, into: anchor, layoutParent: layoutParent)
    }

    private func trackedBody(scopeID: ObjectIdentifier) -> any View {
        ObservableStateTracking.withScope(id: scopeID,
                                          invalidate: makeInvalidation(scopeID: scopeID)) {
            anyBody(of: view)
        }
    }

    private func makeInvalidation(scopeID: ObjectIdentifier) -> () -> Void {
        { [weak self, weak graph] in
            guard let self, let graph else { return }
            let capturedAnim = ActiveAnimationContext.current
            graph.recomposer.invalidate(
                scopeID: scopeID,
                animation: capturedAnim
            ) { [weak self] in
                self?.recompose()
            }
        }
    }

    /// Read `view.body` through an existential boundary. We don't care about
    /// the concrete `Body` type — only that it's a `View`.
    private func anyBody(of view: any View) -> any View {
        func extract<V: View>(_ v: V) -> any View { v.body }
        return extract(view)
    }
}

// MARK: - Reconciler matching key

/// Composite key used by the reconciler to look up an old child by its
/// declared identity. `tag` is the inner view type's reflected name; `key`
/// is the value supplied via `.id(_:)`.
fileprivate struct KeyedSlot: Hashable {
    let tag: String
    let key: AnyHashable
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
