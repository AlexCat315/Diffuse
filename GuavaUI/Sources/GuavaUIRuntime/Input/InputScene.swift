import Foundation
import CoreGraphics
import EngineKernel
import PlatformShell

/// Phase 5a foundation. An `InputNode` is the per-`Node` retained record on
/// the input side. Phase 5a only mirrors structure + classification; the
/// existing `EventDispatcher` / `HitTester` keep walking the `Node` tree.
/// Phase 5b will pivot dispatch to consume this tree so per-frame hit-test
/// state and focus-chain traversal can be cached/spatially indexed without
/// re-walking the entire `Node` graph each event.
public final class InputNode {

    public weak var node: Node?
    public weak var scene: InputScene?
    public weak var parent: InputNode?
    public internal(set) var children: [InputNode] = []

    /// Stable identity inherited from the paired Node. Survives reuse across
    /// recompose so any future per-input-node state (focus index, cached
    /// hit-test geometry) doesn't churn.
    public let elementID: ElementID

    // MARK: - Mirrored input properties
    //
    // These are snapshots of `Node` fields taken at last sync. The dispatch
    // layer reads them rather than poking back at the Node so future spatial
    // indices / focus-chain caches can be invalidated by classification
    // changes alone.

    public internal(set) var isHitTestable: Bool = true
    public internal(set) var isFocusable: Bool = false
    public internal(set) var clipsToBounds: Bool = false
    public internal(set) var cursor: SystemCursor?
    public internal(set) var textInputArea: TextInputArea?

    /// True when at least one event handler is registered for the paired
    /// Node in `InteractionRegistry`. Phase 5b uses this to cull walks into
    /// subtrees that can never deliver an event.
    public internal(set) var hasAnyHandler: Bool = false

    init(node: Node) {
        self.node = node
        self.elementID = node.id
        node.inputNode = self
        refreshFromNode()
    }

    /// Re-read mirrored properties from the bound `Node`. Called after
    /// materialise, after primitive `_updateNode`, and after reconcile.
    /// Cheap (handful of property loads) so callers can invoke freely.
    public func refreshFromNode() {
        guard let node else {
            isHitTestable = false
            isFocusable = false
            clipsToBounds = false
            cursor = nil
            textInputArea = nil
            hasAnyHandler = false
            return
        }
        isHitTestable = node.isHitTestable
        isFocusable = node.isFocusable
        clipsToBounds = node.clipsToBounds
        cursor = node.cursor
        textInputArea = node.attachments[TextInputAttachmentKey.area] as? TextInputArea
        // hasAnyHandler is filled in by `InputScene.refreshHandlers(for:)`
        // when the registry is wired in Phase 5b. For now leave the cached
        // value alone so this method is safe to call without a registry.
    }
}

/// Mirror of the `Node` tree dedicated to the input side. Owns one
/// `InputNode` per Node and answers structural queries (focus chain
/// enumeration, hover-path classification) that the future per-event cache
/// will hang off.
public final class InputScene {

    public private(set) var root: InputNode?

    /// Monotonic counter bumped every time the mirror's structure changes
    /// (install / reconcileChildren / tearDown). Downstream caches
    /// (FocusChain enumeration, future spatial indices) compare against
    /// this to invalidate lazily without observing each mutation.
    public private(set) var version: Int = 0

    /// Node identity → InputNode map. Lookups are O(1).
    private var byNode: [ObjectIdentifier: InputNode] = [:]

    // MARK: - Phase 5c: last hit-test cache
    //
    // Repeated dispatch at the same screen point (mouse held still while
    // wheel-scrolling, motion events arriving at sub-pixel-equal positions,
    // synthetic re-dispatches) is common. Cache the most recent
    // `HitTester.hitTest(scene:point:)` answer keyed by the mirror's
    // structural `version` plus the exact point. The cache is invalidated
    // automatically when:
    //   - structure changes (install / reconcileChildren / tearDown bump
    //     `version`), or
    //   - any node's classification is refreshed (`refresh(node:)`).
    private var hitCacheValid: Bool = false
    private var hitCacheVersion: Int = -1
    private var hitCachePoint: CGPoint = .zero
    private var hitCacheResult: HitResult?
    public private(set) var hitCacheHits: Int = 0
    public private(set) var hitCacheMisses: Int = 0

    /// Read the cached hit-test answer for `point`. Returns `nil` when the
    /// cache cannot be served and the caller must walk the mirror.
    /// `result` may legitimately be `nil` on a hit (cached miss).
    public func cachedHitTest(at point: CGPoint) -> (cached: Bool, result: HitResult?) {
        guard hitCacheValid,
              hitCacheVersion == version,
              hitCachePoint == point else {
            return (false, nil)
        }
        hitCacheHits &+= 1
        return (true, hitCacheResult)
    }

    /// Store the hit-test answer just produced by walking the mirror.
    public func storeHitTest(at point: CGPoint, result: HitResult?) {
        hitCacheValid = true
        hitCacheVersion = version
        hitCachePoint = point
        hitCacheResult = result
        hitCacheMisses &+= 1
    }

    /// Drop the cached hit-test answer. Called automatically on `refresh`,
    /// exposed for tests and unusual hosts.
    public func invalidateHitCache() {
        hitCacheValid = false
        hitCacheResult = nil
    }

    public init() {}

    public func inputNode(for node: Node) -> InputNode? {
        byNode[ObjectIdentifier(node)]
    }

    /// Replace the root and rebuild the entire InputNode mirror from
    /// `node`. Called by `ViewGraph.install(root:)`.
    public func install(rootNode: Node) {
        byNode.removeAll(keepingCapacity: true)
        let obj = InputNode(node: rootNode)
        obj.scene = self
        byNode[ObjectIdentifier(rootNode)] = obj
        root = obj
        rebuildSubtree(parent: obj)
        version &+= 1
    }

    /// Re-mirror the children of a `Node` after structural reconcile. Reused
    /// children keep their existing InputNode so any future per-node cache
    /// state survives.
    public func reconcileChildren(of parentNode: Node) {
        guard let parentInput = byNode[ObjectIdentifier(parentNode)] else { return }
        var existing: [ObjectIdentifier: InputNode] = [:]
        for child in parentInput.children {
            if let n = child.node { existing[ObjectIdentifier(n)] = child }
        }
        var rebuilt: [InputNode] = []
        rebuilt.reserveCapacity(parentNode.children.count)
        var seen: Set<ObjectIdentifier> = []
        for childNode in parentNode.children {
            let key = ObjectIdentifier(childNode)
            seen.insert(key)
            if let kept = existing[key] {
                kept.parent = parentInput
                kept.scene = self
                kept.refreshFromNode()
                rebuilt.append(kept)
            } else {
                let made = InputNode(node: childNode)
                made.parent = parentInput
                made.scene = self
                byNode[key] = made
                rebuilt.append(made)
                rebuildSubtree(parent: made)
            }
        }
        for (key, obj) in existing where !seen.contains(key) {
            tearDown(obj)
            _ = key
        }
        parentInput.children = rebuilt
        parentInput.refreshFromNode()
        version &+= 1
    }

    /// Re-read mirrored input properties for `node` (and only that node).
    /// Used after primitive `_updateNode` runs in `updateInPlace`.
    public func refresh(node: Node) {
        byNode[ObjectIdentifier(node)]?.refreshFromNode()
        // Classification may have flipped (e.g. isHitTestable / clipsToBounds);
        // the cheapest correct response is to drop the per-point hit cache.
        // FocusChain still keys off `version`, which we deliberately do not
        // bump here.
        invalidateHitCache()
    }

    /// Drop a single Node's InputNode (and its descendants).
    public func tearDown(node: Node) {
        guard let obj = byNode[ObjectIdentifier(node)] else { return }
        if let parent = obj.parent,
           let idx = parent.children.firstIndex(where: { $0 === obj }) {
            parent.children.remove(at: idx)
        }
        tearDown(obj)
        if root === obj { root = nil }
        version &+= 1
    }

    private func tearDown(_ obj: InputNode) {
        for child in obj.children { tearDown(child) }
        obj.children.removeAll(keepingCapacity: false)
        if let n = obj.node {
            byNode.removeValue(forKey: ObjectIdentifier(n))
        }
    }

    private func rebuildSubtree(parent: InputNode) {
        guard let parentNode = parent.node else { return }
        var built: [InputNode] = []
        built.reserveCapacity(parentNode.children.count)
        for child in parentNode.children {
            let obj = InputNode(node: child)
            obj.parent = parent
            obj.scene = self
            byNode[ObjectIdentifier(child)] = obj
            built.append(obj)
            rebuildSubtree(parent: obj)
        }
        parent.children = built
    }

    // MARK: - Diagnostics

    /// Total InputNode count, including the root.
    public var nodeCount: Int { byNode.count }

    /// Snapshot of every focusable InputNode in tree order. Phase 5b will
    /// promote this into the live focus-chain cache; Phase 5a exposes it
    /// only for diagnostics + tests.
    public func focusables() -> [InputNode] {
        guard let root else { return [] }
        var out: [InputNode] = []
        collectFocusables(root, into: &out)
        return out
    }

    /// Snapshot of every InputNode that participates in hit-testing
    /// (`isHitTestable == true`). Useful for inventory / coverage.
    public func hitTestables() -> [InputNode] {
        guard let root else { return [] }
        var out: [InputNode] = []
        collectHitTestables(root, into: &out)
        return out
    }

    private func collectFocusables(_ obj: InputNode, into out: inout [InputNode]) {
        if obj.isFocusable { out.append(obj) }
        for c in obj.children { collectFocusables(c, into: &out) }
    }

    private func collectHitTestables(_ obj: InputNode, into out: inout [InputNode]) {
        if obj.isHitTestable { out.append(obj) }
        for c in obj.children { collectHitTestables(c, into: &out) }
    }
}
