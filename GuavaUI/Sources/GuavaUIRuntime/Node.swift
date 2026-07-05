import Foundation
import PlatformShell

/// A retained-mode node in the GuavaUI scene tree.
///
/// Nodes are reference types — identity is by pointer.
/// Dirty flags propagate upward so the root always knows when a flush is needed.
///
/// Invariant: the scene tree is owned and mutated only on the main thread (the
/// host run loop drives compose / layout / dispatch there). `@unchecked
/// Sendable` records that contract — nodes are never mutated concurrently — so
/// they can cross the `Sendable` boundaries the runtime API imposes without
/// per-field synchronisation.
public final class Node: @unchecked Sendable {

    // MARK: - Identity

    /// Stable runtime identifier minted at construction. Phase 1: surfaced
    /// through `SceneInspector` so DevTools can correlate nodes across
    /// snapshots and invalidation events. Future phases key state, layout,
    /// render and input data off this id rather than `ObjectIdentifier`.
    public let id: ElementID

    // MARK: - Tree links

    /// Ordered children. Use `addChild` / `removeChild` to mutate.
    public private(set) var children: [Node] = []

    /// Fast-path hint for hit-testing and rendering. Most UI containers never
    /// set child zIndex, so they can traverse children in tree order without
    /// allocating and sorting on every input/render pass.
    internal private(set) var childrenMayNeedZSort: Bool = false

    /// Bumped for this node and all ancestors whenever descendant membership
    /// or sibling order changes. Primitives such as ScrollView use it to keep
    /// subtree-derived caches valid without rescanning every frame.
    public private(set) var subtreeStructureVersion: UInt64 = 0

    /// Weak reference to avoid retain cycles.
    public private(set) weak var parent: Node?

    // MARK: - State

    /// True after `markDirty()` and before the next `NodeTree.flush()`.
    public internal(set) var isDirty: Bool = false

    /// True after a visual mutation and before the next successful render.
    /// Propagates upward so the root can answer "does any subtree need
    /// repaint?" in O(1) during the host run loop.
    public internal(set) var renderDirty: Bool = false

    /// The rectangle assigned by the layout engine (Phase 3).
    /// Coordinates are local to the parent node.
    ///
    /// Geometry single funnel (坏味 #1): `frame` and the other geometry /
    /// hit-classification fields below (`contentOffset`, `zIndex`,
    /// `clipsToBounds`, `isHitTestable`) all route their `didSet` through
    /// `invalidateGeometry` — the one place that drops the hit cache. There is
    /// no second invalidation path, so a moving property cannot be added that
    /// silently forgets to invalidate (the "works once then stops responding
    /// after a reflow" bug class).
    public var frame: CGRect = .zero {
        didSet {
            if oldValue != frame {
                invalidateGeometry(reason: .layoutChange)
            }
        }
    }

    /// Weak link to this node's `LayoutNode`, set by `ViewGraph` during
    /// materialisation. Lets `_PrimitiveView._updateNode` drive layout
    /// dimensions from theme tokens (resolved on the node) without
    /// needing the geometry to live on the View struct or be re-read
    /// inside `_updateLayout`, which has no node handle.
    public weak var layoutNode: LayoutNode?

    /// Phase 4a back-pointer to the paired `RenderObject`. The `RenderTree`
    /// owns the strong reference; this is just a hop so style mutations on
    /// the node can refresh the render-side layer classification when
    /// Phase 4b's cache lands.
    public weak var renderObject: RenderObject?

    // MARK: - Interaction (Phase 6.1)

    /// When false, hit-testing skips this node (children are still visited
    /// unless `clipsToBounds` excludes them by frame). Routes through the
    /// geometry funnel so toggling it at runtime drops the hit cache.
    public var isHitTestable: Bool = true {
        didSet {
            if oldValue != isHitTestable {
                invalidateGeometry(reason: .styleSet(field: "isHitTestable"))
            }
        }
    }

    /// When true, this node may receive keyboard focus (FocusChain consideration).
    public var isFocusable: Bool = false

    /// When true, hit-testing rejects child hits that fall outside this node's frame.
    /// Also a hint to the renderer (Phase 6.3 `.clip()` modifier).
    public var clipsToBounds: Bool = false {
        didSet {
            if oldValue != clipsToBounds {
                invalidateGeometry(reason: .styleSet(field: "clipsToBounds"))
            }
        }
    }

    // MARK: - Visual (Phase 6.3)

    /// Solid background fill. `nil` = transparent (no fill emitted).
    public var backgroundColor: Color? {
        didSet {
            if oldValue != backgroundColor {
                markRenderDirty(reason: .styleSet(field: "backgroundColor"))
            }
        }
    }

    /// Corner radius (in pixels) applied to the background fill. The clip
    /// rectangle from `clipsToBounds` remains axis-aligned — child content
    /// is not rounded yet (Phase 7).
    public var cornerRadius: Float = 0 {
        didSet {
            if oldValue != cornerRadius {
                markRenderDirty(reason: .styleSet(field: "cornerRadius"))
            }
        }
    }

    /// Stroke colour painted as an inset border around the background fill.
    /// Rendered by `NodeRenderer` as an outer rounded rect of the border
    /// colour with the background rect inset by `borderWidth` painted on
    /// top — gives a correct rounded-rect border without needing a real
    /// stroke primitive on the GPU side.
    public var borderColor: Color? {
        didSet {
            if oldValue != borderColor {
                markRenderDirty(reason: .styleSet(field: "borderColor"))
            }
        }
    }

    /// Width of the border in pixels. `0` (default) skips border rendering
    /// even when `borderColor` is set.
    public var borderWidth: Float = 0 {
        didSet {
            if oldValue != borderWidth {
                markRenderDirty(reason: .styleSet(field: "borderWidth"))
            }
        }
    }

    /// Drop-shadow colour painted under the background fill. `nil` (default)
    /// or zero-alpha skips shadow rendering.
    public var shadowColor: Color? {
        didSet {
            if oldValue != shadowColor {
                markRenderDirty(reason: .styleSet(field: "shadowColor"))
            }
        }
    }
    public var shadowOffsetX: Float = 0 {
        didSet {
            if oldValue != shadowOffsetX {
                markRenderDirty(reason: .styleSet(field: "shadowOffsetX"))
            }
        }
    }
    public var shadowOffsetY: Float = 0 {
        didSet {
            if oldValue != shadowOffsetY {
                markRenderDirty(reason: .styleSet(field: "shadowOffsetY"))
            }
        }
    }
    /// Logical blur radius. The current renderer downgrades this to a stack
    /// of expanded translucent rounded rects (cheap fake shadow).
    public var shadowBlur: Float = 0 {
        didSet {
            if oldValue != shadowBlur {
                markRenderDirty(reason: .styleSet(field: "shadowBlur"))
            }
        }
    }

    /// Foreground tint. Used by Text and tinted Image. `nil` = renderer default.
    public var foregroundColor: Color? {
        didSet {
            if oldValue != foregroundColor {
                markRenderDirty(reason: .styleSet(field: "foregroundColor"))
            }
        }
    }

    /// Alpha multiplier in 0..1 applied to this node's draws (and inherited
    /// transitively in later phases). Default 1.
    public var opacity: Float = 1 {
        didSet {
            if oldValue != opacity {
                markRenderDirty(reason: .styleSet(field: "opacity"))
            }
        }
    }

    /// Paint/input stacking order among siblings. Higher values render later
    /// and receive hit-testing first. Equal values preserve tree order.
    public var zIndex: Float = 0 {
        didSet {
            if oldValue != zIndex {
                parent?.childZIndexDidChange(from: oldValue, to: zIndex)
                // z-order reorders hit/paint among siblings. The InputScene is
                // shared across the whole tree (one per tree), so invalidating
                // via this node's own scene is equivalent to the parent's and
                // also covers the root.
                invalidateGeometry(reason: .styleSet(field: "zIndex"))
            }
        }
    }

    /// Optional custom-draw hook invoked after the background fill but before
    /// recursing into children. The closure receives the active `DrawList` and
    /// the node's absolute origin (top-left in viewport space).
    ///
    /// Used by leaf primitives such as Text/Image to emit content-specific
    /// geometry without subclassing `Node`.
    public var draw: ((DrawList, CGPoint) -> Void)? {
        didSet {
            markRenderDirty(reason: .styleSet(field: "draw"))
        }
    }

    /// Optional draw hook invoked AFTER children render. Used for chrome that
    /// must overlay scrolled content (e.g. ScrollView scrollbars).
    public var overlayDraw: ((DrawList, CGPoint) -> Void)? {
        didSet {
            markRenderDirty(reason: .styleSet(field: "overlayDraw"))
        }
    }

    /// Optional hook invoked after a layout pass writes this node's frame back
    /// from the layout tree. Used by primitives that mirror layout-derived
    /// geometry into non-tree state, such as portal overlays.
    public var layoutDidUpdate: ((Node) -> Void)?

    /// Children render translated by `-contentOffset`. Used by ScrollView to
    /// scroll its content while keeping its own clip rect anchored.
    public var contentOffset: CGPoint = .zero {
        didSet {
            if oldValue != contentOffset {
                invalidateGeometry(reason: .styleSet(field: "contentOffset"))
            }
        }
    }

    /// Desired system cursor when the pointer is hovering this node. Resolved
    /// by `EventDispatcher` walking the hover path leaf → root and using the
    /// deepest non-nil value. `nil` (the default) inherits from ancestors.
    public var cursor: SystemCursor?

    // MARK: - Compose reconciliation (Phase 6.6)

    /// Identifier for the View kind that materialised this node, derived from
    /// `String(reflecting: type(of: view))`. ViewGraph uses it to decide
    /// whether a recompose can reuse this node in place (preserving any
    /// state in `attachments`) or must rebuild.
    public var viewTag: String?

    /// Optional explicit identity supplied via the `.id(_:)` modifier.
    /// Phase 2 reconciler matches `(viewTag, key)` first, then falls back to
    /// sequential `viewTag` matching. Survives reorder so primitives keyed
    /// by `.id` keep their attachments and child scopes when their position
    /// among siblings changes.
    public var key: AnyHashable?

    /// Side table for primitive-owned persistent state that must survive a
    /// recompose. Keyed by an arbitrary string chosen by the primitive.
    /// Example: `TextField` stores its `FieldState` (cursor, selection)
    /// here so editing state is not reset every time the parent recomposes.
    public var attachments: [String: Any] = [:]

    // MARK: - CompositionLocal storage (Phase 7.5)

    /// Values pushed onto this node by `CompositionLocal` providers, keyed by
    /// the provider's identity. Lookup walks the parent chain until a value
    /// is found; absent providers fall back to `CompositionLocal.defaultValue`.
    public var compositionValues: [ObjectIdentifier: Any] = [:]

    /// Push a value for `local` onto this node. Replaces any prior value
    /// stored here for the same key.
    public func setCompositionValue<Value>(_ local: CompositionLocal<Value>,
                                           _ value: Value) {
        compositionValues[local.key] = value
    }

    /// Resolve `local` by walking up the parent chain. Returns the nearest
    /// ancestor's stored value, or `local.defaultValue` if none exists.
    public func compositionValue<Value>(of local: CompositionLocal<Value>) -> Value {
        var cursor: Node? = self
        while let node = cursor {
            if let raw = node.compositionValues[local.key], let typed = raw as? Value {
                return typed
            }
            cursor = node.parent
        }
        return local.defaultValue
    }

    // MARK: - Resources (坏味 #4)

    /// External registrations tied to this node's lifetime. Released when the
    /// node leaves the tree — see `removeChild` / `unmountResourcesRecursively`.
    private var resources: [NodeResource] = []

    /// Tie an external registration (e.g. a portal/overlay entry) to this
    /// node's lifetime. Mounts immediately; `unmount` runs automatically when
    /// the node is removed from its parent for any reason.
    public func addResource(_ resource: NodeResource) {
        resources.append(resource)
        resource.mount(node: self)
    }

    /// First attached resource of the given type, if any. Primitives use this
    /// on reuse (`_updateNode`) to reach the resource created in `_makeNode`.
    public func firstResource<R: NodeResource>(_ type: R.Type) -> R? {
        for resource in resources {
            if let match = resource as? R { return match }
        }
        return nil
    }

    /// Release this node and every descendant from the live tree, leaf → root,
    /// so a parent observes a fully-released subtree (规则 2). Unmounts node-owned
    /// resources and releases the per-window singletons keyed by this exact node
    /// (pointer capture, focus). Idempotent.
    private func releaseFromTree() {
        for child in children {
            child.releaseFromTree()
        }
        for resource in resources {
            resource.unmount(node: self)
        }
        // A node leaving the tree must not remain the capture target — otherwise
        // every later event routes to a detached node (the stuck-capture bug) —
        // nor keep focus. Mirrors GuavaKit's `UIContext.detach`. The holders are
        // nil outside a window scope (e.g. raw-Node tests), so this is a no-op
        // there.
        if PointerCaptureHolder.current?.target === self {
            PointerCaptureHolder.current?.release()
        }
        if FocusChainHolder.current?.focused === self {
            FocusChainHolder.current?.clear()
        }
    }

    public init() {
        self.id = IdentityAllocator.shared.allocate()
    }

    // MARK: - Tree mutation

    public func addChild(_ child: Node) {
        child.parent = self
        children.append(child)
        if child.zIndex != 0 {
            childrenMayNeedZSort = true
        }
        bumpSubtreeStructureVersion()
        markRenderDirty(reason: .structuralChange)
    }

    public func removeChild(_ child: Node) {
        let previousCount = children.count
        let removedMayNeedZSort = child.zIndex != 0
        children.removeAll { $0 === child }
        child.parent = nil
        if children.count != previousCount {
            // The child (and its whole subtree) is leaving the tree — release
            // every resource it registered plus the singletons it held (capture,
            // focus). This is the single authoritative cleanup path; no modifier
            // or ViewGraph side-effect is needed (坏味 #4).
            child.releaseFromTree()
            if removedMayNeedZSort {
                recomputeChildrenMayNeedZSort()
            }
            bumpSubtreeStructureVersion()
            markRenderDirty(reason: .structuralChange)
        }
    }

    public func removeFromParent() {
        parent?.removeChild(self)
    }

    /// Reassign this node's children to `ordered` without invoking teardown
    /// on any of them. `ordered` must be exactly the same set as the current
    /// children (any subset/superset is a programmer error and triggers a
    /// `precondition` failure). Used by the keyed reconciler to apply a new
    /// sibling order after `addChild` / `tearDown` have already settled
    /// membership.
    public func reorderChildren(_ ordered: [Node]) {
        precondition(ordered.count == children.count,
                     "reorderChildren: count mismatch (\(ordered.count) vs \(children.count))")
        let currentIDs = Set(children.map { ObjectIdentifier($0) })
        let nextIDs = Set(ordered.map { ObjectIdentifier($0) })
        precondition(currentIDs == nextIDs,
                     "reorderChildren: membership mismatch")
        if children.elementsEqual(ordered, by: { $0 === $1 }) {
            return
        }
        // Reorder only the source of truth. The render mirror is re-synced
        // exclusively by the reconciler's `RenderTree.reconcileChildren`, which
        // rebuilds its child list in this `children` order right after every
        // `reorderChildren` call (坏味 #2: one sync path, no hand-written
        // second one that can drift). Hit-testing reads this order live.
        children = ordered
        bumpSubtreeStructureVersion()
        markRenderDirty(reason: .structuralChange)
    }

    private func childZIndexDidChange(from oldValue: Float, to newValue: Float) {
        if oldValue == 0, newValue != 0 {
            childrenMayNeedZSort = true
        } else if oldValue != 0, newValue == 0 {
            recomputeChildrenMayNeedZSort()
        }
    }

    private func recomputeChildrenMayNeedZSort() {
        childrenMayNeedZSort = children.contains { $0.zIndex != 0 }
    }

    private func bumpSubtreeStructureVersion() {
        subtreeStructureVersion &+= 1
        parent?.bumpSubtreeStructureVersion()
    }

    // MARK: - Geometry single funnel (坏味 #1)

    /// The one and only path a geometry / hit-classification mutation takes to
    /// notify caches. Every such property's `didSet` calls this after a cheap
    /// value diff; nothing else invalidates the hit cache. Because there is a
    /// single site, a newly added moving / hit-affecting property cannot ship
    /// without invalidation — the structural cause of the "control responds
    /// once then goes dead after a resize / reflow / scroll" bug is removed.
    ///
    /// `reason` is forwarded to render bookkeeping / the invalidation log.
    /// Hit-testing walks the live `Node` tree every time (Phase 7 removed the
    /// input mirror and its cache), so a geometry / hit-classification change is
    /// reflected on the next hit-test with nothing to invalidate — the stale-hit
    /// bug class (坏味 #1) is structurally impossible. The funnel remains the one
    /// place that maps a geometry change to render invalidation.
    private func invalidateGeometry(reason: InvalidationSource) {
        markRenderDirty(reason: reason)
    }

    // MARK: - Dirty propagation

    /// Mark this node dirty and propagate the flag upward to every ancestor.
    ///
    /// Ancestors are flagged so the tree root knows a flush is needed
    /// without scanning every node on each frame.
    public func markDirty(reason: InvalidationSource = .unknown) {
        InvalidationLogHolder.current?.record(
            DirtyReason(target: id, source: reason, phase: .layout)
        )
        InvalidationLogHolder.current?.record(
            DirtyReason(target: id, source: reason, phase: .render)
        )
        propagateDirty(layoutDirty: true, renderDirty: true)
        // Phase 4b: a layout dirty implies the layer's geometry may move, so
        // also invalidate the enclosing layer cache so it re-records.
        renderObject?.invalidateLayerChain()
    }

    public func markRenderDirty(reason: InvalidationSource = .unknown) {
        let wasRenderDirty = renderDirty
        InvalidationLogHolder.current?.record(
            DirtyReason(target: id, source: reason, phase: .render)
        )
        propagateDirty(layoutDirty: false, renderDirty: true)
        if wasRenderDirty {
            if isLayerClassificationInvalidation(reason) {
                renderObject?.refreshLayerClassification()
            }
            return
        }
        // Phase 4b: a style mutation may have promoted/demoted this node to a
        // layer root (clipsToBounds, opacity, shadowColor changes); refresh
        // before invalidating so the cache state lands on the right object.
        renderObject?.refreshLayerClassification()
        renderObject?.invalidateLayerChain()
    }

    private func propagateDirty(layoutDirty: Bool, renderDirty: Bool) {
        let needsLayoutPropagation = layoutDirty && !isDirty
        let needsRenderPropagation = renderDirty && !self.renderDirty
        let shouldPropagate = needsLayoutPropagation || needsRenderPropagation

        if layoutDirty {
            isDirty = true
        }
        if renderDirty {
            self.renderDirty = true
        }

        if shouldPropagate {
            parent?.propagateDirty(layoutDirty: layoutDirty, renderDirty: renderDirty)
        }
    }

    private func isLayerClassificationInvalidation(_ reason: InvalidationSource) -> Bool {
        guard case .styleSet(let field) = reason else { return false }
        return field == "clipsToBounds" || field == "opacity" || field == "shadowColor"
    }
}
