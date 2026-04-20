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
    public var frame: CGRect = .zero

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
