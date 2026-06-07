/// A retained node in the UI tree.
///
/// Two deliberate constraints make whole bug classes unrepresentable:
///
/// * **Geometry is `private(set)`** — the only mutator is `setGeometry(_:)`,
///   which always routes through `UIContext.invalidate`. There is no second way
///   to move a node, so no cache can ever be left stale by a forgotten hook.
/// * **Children and resources are managed through methods** (`append`,
///   `removeFromParent`, `addResource`) that drive mount/unmount, so a node that
///   leaves the tree always releases what it registered.
public final class UINode {

    public let id: NodeID

    public private(set) weak var parent: UINode?
    public private(set) var children: [UINode] = []

    /// Visual + interaction geometry (layout *output*). Read freely; mutate only
    /// via `setGeometry` — typically the layout engine does this for you.
    public private(set) var geometry: Geometry

    /// Layout *input*. Changing it marks the tree `.layout`-dirty so the next
    /// `UIContext.layoutIfNeeded` recomputes frames.
    public private(set) var layoutStyle = LayoutStyle()

    /// Pointer/hover handlers for this node. Lives on the node, so it shares the
    /// node's lifetime — no global handler registry to leak or desync.
    public var interaction = Interaction()

    /// Visual description (paint *input*). Changing it marks the tree
    /// `.paint`-dirty so the next render rebuilds the display list.
    public private(set) var paint = Paint()

    /// Intrinsic content size for leaves (e.g. measured text). The layout engine
    /// uses it when a leaf's dimension is `.auto`.
    public private(set) var intrinsicSize: Size?

    /// Text to draw for this node, if any (string + colour + size). Set by `Text`.
    public private(set) var textContent: (string: String, color: Color, size: Float)?

    /// The context (per-tree) this node is currently attached to, if any.
    public internal(set) weak var context: UIContext?

    /// External registrations tied to this node's lifetime (see `NodeResource`).
    private var resources: [NodeResource] = []

    /// Optional debug label, purely for diagnostics/tests.
    public var debugName: String?

    public init(id: NodeID = NodeID(), geometry: Geometry = Geometry()) {
        self.id = id
        self.geometry = geometry
    }

    // MARK: - Geometry (the single funnel)

    /// The one and only way to change geometry. Diffs the change into dirty
    /// flags and notifies the context so every interested cache invalidates.
    /// Returns the flags that changed (empty if nothing did).
    @discardableResult
    public func setGeometry(_ new: Geometry) -> DirtyFlags {
        let flags = Geometry.diff(geometry, new)
        guard !flags.isEmpty else { return [] }
        geometry = new
        context?.invalidate(self, flags)
        return flags
    }

    /// Convenience mutators — all route through `setGeometry`, so they inherit
    /// the invalidation guarantee for free.
    @discardableResult public func setFrame(_ frame: Rect) -> DirtyFlags {
        var g = geometry; g.frame = frame; return setGeometry(g)
    }
    @discardableResult public func setContentOffset(_ offset: Point) -> DirtyFlags {
        var g = geometry; g.contentOffset = offset; return setGeometry(g)
    }
    @discardableResult public func setZIndex(_ z: Float) -> DirtyFlags {
        var g = geometry; g.zIndex = z; return setGeometry(g)
    }
    @discardableResult public func setHitTestable(_ on: Bool) -> DirtyFlags {
        var g = geometry; g.isHitTestable = on; return setGeometry(g)
    }
    @discardableResult public func setClipsToBounds(_ on: Bool) -> DirtyFlags {
        var g = geometry; g.clipsToBounds = on; return setGeometry(g)
    }

    /// Update layout inputs. Marks the tree `.layout`-dirty (does not lay out
    /// immediately — the host drives that via `UIContext.layoutIfNeeded`).
    public func setLayoutStyle(_ style: LayoutStyle) {
        guard style != layoutStyle else { return }
        layoutStyle = style
        context?.invalidate(self, [.layout])
    }

    /// In-place edit convenience: `node.modifyLayout { $0.flexGrow = 1 }`.
    public func modifyLayout(_ edit: (inout LayoutStyle) -> Void) {
        var s = layoutStyle
        edit(&s)
        setLayoutStyle(s)
    }

    /// Update the visual description. Marks the tree `.paint`-dirty.
    public func setPaint(_ newPaint: Paint) {
        guard newPaint != paint else { return }
        paint = newPaint
        context?.invalidate(self, [.paint])
    }

    /// In-place paint edit (composes with existing paint instead of replacing).
    public func modifyPaint(_ edit: (inout Paint) -> Void) {
        var p = paint; edit(&p); setPaint(p)
    }

    public func setIntrinsicSize(_ size: Size?) {
        guard size != intrinsicSize else { return }
        intrinsicSize = size
        context?.invalidate(self, [.layout, .paint])
    }

    public func setText(_ string: String, color: Color, size: Float) {
        if let t = textContent, t.string == string, t.color == color, t.size == size { return }
        textContent = (string, color, size)
        context?.invalidate(self, [.paint])
    }

    /// Replace only the colour of the already-set text (modifier path).
    public func modifyTextColor(_ color: Color) {
        guard let t = textContent, t.color != color else { return }
        textContent = (t.string, color, t.size)
        context?.invalidate(self, [.paint])
    }

    /// Replace only the font size of the already-set text (modifier path).
    public func modifyTextSize(_ size: Float) {
        guard let t = textContent, t.size != size else { return }
        textContent = (t.string, t.color, size)
        context?.invalidate(self, [.paint])
    }

    // MARK: - Hierarchy

    /// Append `child` (re-parenting it if needed). If this node is attached to a
    /// context, the child's whole subtree is mounted into it.
    public func append(_ child: UINode) {
        child.removeFromParent()
        child.parent = self
        children.append(child)
        if let context { context.attach(child) }
        context?.invalidate(self, [.hierarchy, .layout, .paint])
    }

    /// Remove this node (and its subtree) from its parent. Detaching from the
    /// context guarantees every resource in the subtree is released.
    public func removeFromParent() {
        guard let parent else { return }
        let ctx = context
        parent.children.removeAll { $0 === self }
        self.parent = nil
        if let ctx { ctx.detach(self) }
        ctx?.invalidate(parent, [.hierarchy, .layout, .paint])
    }

    // MARK: - Resources

    /// Tie an external registration to this node's lifetime. If already attached,
    /// it mounts immediately; otherwise it mounts when the node is attached.
    public func addResource(_ resource: NodeResource) {
        resources.append(resource)
        if let context { resource.mount(node: self, context: context) }
    }

    /// Reorder existing children to match `ordered` (which must be a permutation
    /// of the current children — used by the reconciler after reuse). Parent
    /// links are unchanged; only paint/hit/layout order is affected.
    func reorderChildren(_ ordered: [UINode]) {
        guard ordered.count == children.count else { return }
        children = ordered
        context?.invalidate(self, [.hierarchy, .layout, .paint])
    }

    /// First attached resource of the given type, if any.
    public func firstResource<R: NodeResource>(_ type: R.Type) -> R? {
        for r in resources { if let match = r as? R { return match } }
        return nil
    }

    // Called by UIContext during attach/detach — not part of the public surface.
    func mountResources(_ context: UIContext) {
        for r in resources { r.mount(node: self, context: context) }
    }
    func unmountResources(_ context: UIContext) {
        for r in resources { r.unmount(node: self, context: context) }
    }
}

/// Stable, cheap node identity. Allocation is single-threaded (the UI tree is
/// main-thread only), so the monotonic counter is `nonisolated(unsafe)`.
public struct NodeID: Hashable, Sendable {
    nonisolated(unsafe) private static var counter: UInt64 = 0
    public let raw: UInt64
    public init() {
        NodeID.counter &+= 1
        raw = NodeID.counter
    }
}
