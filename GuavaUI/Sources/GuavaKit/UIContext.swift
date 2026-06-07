/// Per-tree (per-window) runtime context.
///
/// `UIContext` is the spine of GuavaKit. It owns:
///   * the **single invalidation funnel** every geometry/hierarchy change flows
///     through (`invalidate`), and the caches that subscribe to it;
///   * the **attach/detach lifecycle** that mounts and — critically — releases
///     node resources;
///   * the per-tree **registries** (hit index now; portals/focus/capture as the
///     rewrite grows) that in the legacy stack were process-global singletons.
///
/// Because it is per-tree and explicitly passed (never a global), one window's
/// state can never corrupt another's.
public final class UIContext {

    public private(set) var root: UINode?

    /// Hit-test cache, invalidated automatically below. Scoped to this tree.
    public let hitIndex = HitTestIndex()

    /// Pointer capture (in-progress drag target). Scoped to this tree and
    /// released automatically when the captured node detaches — see `detach`.
    public let pointerCapture = PointerCapture()

    /// Overlay registry (popovers/menus). Scoped to this tree — never global.
    public let portals = PortalStore()

    /// How `Text` measures itself. Defaults to a standalone approximation; the
    /// editor host swaps in real font metrics.
    public var textMeasurer: TextMeasuring = ApproxTextMeasurer()

    /// Active theme for this context. Semantic modifiers resolve colours and
    /// fonts against this theme at apply time.
    public var theme: Theme = .dark

    /// Accumulated dirty flags for the current frame (drained by the host's
    /// layout/paint pass). Exposed read-only for diagnostics/tests.
    public private(set) var pendingDirty: DirtyFlags = []

    /// Available size used by the last layout pass; a change forces re-layout.
    private var lastAvailable: Size?

    public init() {}

    // MARK: - Install / teardown

    /// Make `node` the root and mount its whole subtree.
    public func install(root node: UINode) {
        if let old = root { detach(old) }
        root = node
        attach(node)
    }

    // MARK: - The invalidation funnel

    /// Every geometry/hierarchy mutation in the tree ends up here. This is the
    /// ONE place that maps changes to cache invalidation — add a cache, add one
    /// line here; no hook to thread through `UINode` or its `didSet`s.
    public func invalidate(_ node: UINode, _ flags: DirtyFlags) {
        pendingDirty.formUnion(flags)

        // A geometry or hierarchy change can move/insert/remove hittable area,
        // so the hit cache is no longer valid. (This is the invariant the legacy
        // `frame.didSet` forgot — here it is impossible to bypass.)
        if !flags.isDisjoint(with: [.geometry, .hierarchy]) {
            hitIndex.invalidate()
        }
    }

    /// Drain the accumulated dirty flags (host calls this after a layout/paint
    /// pass). Returns what was pending.
    @discardableResult
    public func takeDirty() -> DirtyFlags {
        defer { pendingDirty = [] }
        return pendingDirty
    }

    // MARK: - Lifecycle (mount / unmount resources)

    /// Attach `node` and its subtree to this context, mounting every resource.
    func attach(_ node: UINode) {
        node.context = self
        node.mountResources(self)
        for child in node.children { attach(child) }
        invalidate(node, [.hierarchy, .geometry, .layout, .paint])
    }

    /// Detach `node` and its subtree, releasing every resource. Children are
    /// torn down first (leaf → root) so parents observe a fully-released subtree.
    func detach(_ node: UINode) {
        for child in node.children { detach(child) }
        node.unmountResources(self)
        // A node leaving the tree must not keep the pointer captured — otherwise
        // every later click routes to a dead node (the legacy stuck-capture bug).
        if pointerCapture.target === node { pointerCapture.release() }
        node.context = nil
        hitIndex.invalidate()
        if root === node { root = nil }
    }

    // MARK: - Layout

    /// Run `engine` only when something actually changed — the tree is
    /// `.layout`-dirty or the available size differs from last time. Layout
    /// writes frames via `setFrame`, which re-enters `invalidate` and refreshes
    /// the hit cache automatically. Returns whether a layout pass ran.
    @discardableResult
    public func layoutIfNeeded(engine: LayoutEngine, available: Size) -> Bool {
        guard pendingDirty.contains(.layout) || lastAvailable != available else { return false }
        lastAvailable = available
        if let root { engine.layout(root: root, available: available) }
        // Layout is satisfied; geometry/paint flags raised by setFrame remain for
        // the downstream paint pass.
        pendingDirty.subtract(.layout)
        return true
    }

    // MARK: - Paint

    /// Rebuild the display list only when the tree is `.paint`-dirty (geometry
    /// moves, paint edits, and hierarchy changes all raise `.paint` through the
    /// same funnel). Returns `nil` when nothing needs repainting.
    @discardableResult
    public func renderIfNeeded(painter: Painter = Painter()) -> DisplayList? {
        guard pendingDirty.contains(.paint) else { return nil }
        pendingDirty.subtract(.paint)
        guard let root else { return DisplayList() }
        return painter.paint(root: root)
    }

    // MARK: - Convenience

    public func hitTest(_ point: Point) -> HitTest.Result? {
        hitIndex.hitTest(point, in: root)
    }
}
