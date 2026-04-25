import Foundation
import CoreGraphics

/// Phase 4a foundation. A `RenderObject` is the per-`Node` retained record
/// that a future per-layer DrawList cache will hang state off.
///
/// In Phase 4a the type only mirrors structure and classifies layer roots;
/// `NodeRenderer` still walks the `Node` tree directly each frame.
/// Phase 4b will pivot the renderer to walk this tree and reuse cached
/// DrawList vertices for layers whose subtree is unchanged.
public final class RenderObject {

    public weak var node: Node?
    public weak var parent: RenderObject?
    public internal(set) var children: [RenderObject] = []

    /// Stable identity inherited from the paired Node. Survives reuse across
    /// recompose so cache lookups don't churn.
    public let elementID: ElementID

    /// True when this RenderObject begins a composition group whose subtree
    /// must record into its own DrawList. Computed from Node properties:
    /// clipping, non-opaque opacity, or any drop shadow forces a layer
    /// boundary because the GPU pipeline needs an isolated buffer to clip /
    /// blend / shadow over.
    public internal(set) var isLayerRoot: Bool = true

    /// Snapshot of the absolute origin of this object the last time the
    /// renderer recorded into it. Phase 4b uses this to detect "the layer
    /// only moved" vs "the layer's contents changed".
    public var lastAbsoluteOrigin: CGPoint?

    /// Set by Phase 4b's renderer when the cached DrawList for this layer
    /// is no longer trustworthy and must be re-recorded.
    public var cacheInvalid: Bool = true

    /// Phase 4b: cached DrawList recorded the last time this layer was
    /// composited. Holds vertices in absolute coordinates valid only for the
    /// `lastAbsoluteOrigin` snapshot. `LayerAwareNodeRenderer` reuses this
    /// list when `cacheInvalid == false` and the origin hasn't moved.
    /// Non-layer RenderObjects don't cache (this stays nil).
    public var cachedLayerList: DrawList?

    /// Parent clip stack snapshot at last record. Cache is only valid when
    /// the current parent clip stack equals this snapshot, otherwise scissor
    /// rects baked into `cachedLayerList.batches` are stale.
    public var lastClipStack: [UIRect] = []

    init(node: Node) {
        self.node = node
        self.elementID = node.id
        node.renderObject = self
        refreshLayerClassification()
    }

    /// Walk parents and mark every layer-root cache on the path invalid.
    /// Nested layer DrawLists are appended into their enclosing layer's cached
    /// DrawList, so invalidating only the nearest layer would leave ancestors
    /// free to reuse stale composite output.
    public func invalidateLayerChain() {
        var node: RenderObject? = self
        while let cur = node {
            if cur.isLayerRoot {
                cur.cacheInvalid = true
            }
            node = cur.parent
        }
    }

    /// Re-evaluate `isLayerRoot` from the bound `Node`'s current properties.
    /// Called after style mutations that could change layer-root status.
    public func refreshLayerClassification() {
        guard let node else {
            isLayerRoot = true
            return
        }
        // Root has no parent — always its own layer.
        if parent == nil {
            isLayerRoot = true
            return
        }
        if node.clipsToBounds { isLayerRoot = true; return }
        if node.opacity < 1 { isLayerRoot = true; return }
        if let shadow = node.shadowColor, shadow.a > 0 { isLayerRoot = true; return }
        isLayerRoot = false
    }
}

/// Mirror of the `Node` tree dedicated to the render side. Owns one
/// `RenderObject` per Node and answers structural queries (layer inventory,
/// nearest enclosing layer root, etc) that the future per-layer cache needs.
public final class RenderTree {

    public private(set) var root: RenderObject?

    /// Node identity → RenderObject map. Lookups are O(1).
    private var byNode: [ObjectIdentifier: RenderObject] = [:]

    public init() {}

    public func renderObject(for node: Node) -> RenderObject? {
        byNode[ObjectIdentifier(node)]
    }

    /// Replace the root and rebuild the entire RenderObject mirror from
    /// `node`. Called by `ViewGraph.install(root:)`.
    public func install(rootNode: Node) {
        byNode.removeAll(keepingCapacity: true)
        let obj = RenderObject(node: rootNode)
        byNode[ObjectIdentifier(rootNode)] = obj
        root = obj
        rebuildSubtree(parent: obj)
    }

    /// Re-mirror the children of a `Node` after structural reconcile. New
    /// children get fresh RenderObjects; reused children keep their existing
    /// object so any cached state survives.
    public func reconcileChildren(of parentNode: Node) {
        guard let parentObject = byNode[ObjectIdentifier(parentNode)] else { return }
        var existing: [ObjectIdentifier: RenderObject] = [:]
        for child in parentObject.children {
            if let n = child.node { existing[ObjectIdentifier(n)] = child }
        }
        var rebuilt: [RenderObject] = []
        rebuilt.reserveCapacity(parentNode.children.count)
        var seen: Set<ObjectIdentifier> = []
        for childNode in parentNode.children {
            let key = ObjectIdentifier(childNode)
            seen.insert(key)
            if let kept = existing[key] {
                kept.parent = parentObject
                rebuilt.append(kept)
            } else {
                let made = RenderObject(node: childNode)
                made.parent = parentObject
                byNode[key] = made
                rebuilt.append(made)
                rebuildSubtree(parent: made)
            }
        }
        // Drop torn-down children (and their subtrees) from the registry.
        for (key, obj) in existing where !seen.contains(key) {
            tearDown(obj)
            _ = key
        }
        parentObject.children = rebuilt
        for obj in rebuilt {
            obj.refreshLayerClassification()
            // Cache invalidates whenever children list changes.
            obj.cacheInvalid = true
        }
        parentObject.cacheInvalid = true
    }

    /// Drop a single Node's RenderObject (and its descendants).
    public func tearDown(node: Node) {
        guard let obj = byNode[ObjectIdentifier(node)] else { return }
        if let parent = obj.parent,
           let idx = parent.children.firstIndex(where: { $0 === obj }) {
            parent.children.remove(at: idx)
            parent.cacheInvalid = true
        }
        tearDown(obj)
        if root === obj { root = nil }
    }

    private func tearDown(_ obj: RenderObject) {
        for child in obj.children { tearDown(child) }
        obj.children.removeAll(keepingCapacity: false)
        if let n = obj.node {
            byNode.removeValue(forKey: ObjectIdentifier(n))
        }
    }

    private func rebuildSubtree(parent: RenderObject) {
        guard let parentNode = parent.node else { return }
        var built: [RenderObject] = []
        built.reserveCapacity(parentNode.children.count)
        for child in parentNode.children {
            let obj = RenderObject(node: child)
            obj.parent = parent
            byNode[ObjectIdentifier(child)] = obj
            built.append(obj)
            rebuildSubtree(parent: obj)
        }
        parent.children = built
        parent.refreshLayerClassification()
    }

    // MARK: - Diagnostics

    /// Snapshot of every layer-root RenderObject in pre-order.
    public func layerRoots() -> [RenderObject] {
        guard let root else { return [] }
        var out: [RenderObject] = []
        collectLayerRoots(root, into: &out)
        return out
    }

    private func collectLayerRoots(_ obj: RenderObject, into out: inout [RenderObject]) {
        if obj.isLayerRoot { out.append(obj) }
        for child in obj.children { collectLayerRoots(child, into: &out) }
    }

    /// Count of RenderObjects in the tree (testing/diagnostic).
    public var objectCount: Int { byNode.count }
}
