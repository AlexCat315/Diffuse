import Foundation

/// A retained-mode node in the GuavaUI scene tree.
///
/// Nodes are reference types — identity is by pointer.
/// Dirty flags propagate upward so the root always knows when a flush is needed.
public final class Node: @unchecked Sendable {

    // MARK: - Tree links

    /// Ordered children. Use `addChild` / `removeChild` to mutate.
    public private(set) var children: [Node] = []

    /// Weak reference to avoid retain cycles.
    public private(set) weak var parent: Node?

    // MARK: - State

    /// True after `markDirty()` and before the next `NodeTree.flush()`.
    public internal(set) var isDirty: Bool = false

    /// The rectangle assigned by the layout engine (Phase 3).
    /// Coordinates are local to the parent node.
    public var frame: CGRect = .zero

    // MARK: - Interaction (Phase 6.1)

    /// When false, hit-testing skips this node (children are still visited
    /// unless `clipsToBounds` excludes them by frame).
    public var isHitTestable: Bool = true

    /// When true, this node may receive keyboard focus (FocusChain consideration).
    public var isFocusable: Bool = false

    /// When true, hit-testing rejects child hits that fall outside this node's frame.
    /// Also a hint to the renderer (Phase 6.3 `.clip()` modifier).
    public var clipsToBounds: Bool = false

    // MARK: - Visual (Phase 6.3)

    /// Solid background fill. `nil` = transparent (no fill emitted).
    public var backgroundColor: Color?

    /// Foreground tint. Used by Text and tinted Image. `nil` = renderer default.
    public var foregroundColor: Color?

    /// Alpha multiplier in 0..1 applied to this node's draws (and inherited
    /// transitively in later phases). Default 1.
    public var opacity: Float = 1

    public init() {}

    // MARK: - Tree mutation

    public func addChild(_ child: Node) {
        child.parent = self
        children.append(child)
    }

    public func removeChild(_ child: Node) {
        children.removeAll { $0 === child }
        child.parent = nil
    }

    public func removeFromParent() {
        parent?.removeChild(self)
    }

    // MARK: - Dirty propagation

    /// Mark this node dirty and propagate the flag upward to every ancestor.
    ///
    /// Ancestors are flagged so the tree root knows a flush is needed
    /// without scanning every node on each frame.
    public func markDirty() {
        isDirty = true
        parent?.markDirty()
    }
}
