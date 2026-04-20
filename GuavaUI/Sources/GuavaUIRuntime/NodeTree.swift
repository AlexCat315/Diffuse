/// Owns the root node and drives depth-first traversal.
///
/// Usage:
/// ```swift
/// let tree = NodeTree()
/// tree.root = Node()
/// tree.markDirty(someChild)
/// tree.flush()   // resets all dirty flags; invokes layout + draw in later phases
/// ```
public final class NodeTree: @unchecked Sendable {

    /// The single root of the scene graph.
    public var root: Node?

    public init() {}

    // MARK: - Dirty management

    /// Convenience wrapper around `Node.markDirty()`.
    public func markDirty(_ node: Node) {
        node.markDirty()
    }

    // MARK: - Flush

    /// Depth-first traversal that resets dirty flags on every reachable node.
    ///
    /// Phase 1: dirty-flag reset only.
    /// Phase 3+: will also invoke layout callbacks on dirty nodes.
    /// Phase 5+: will also invoke draw callbacks.
    public func flush() {
        guard let root else { return }
        traverse(root)
    }

    private func traverse(_ node: Node) {
        node.isDirty = false
        for child in node.children {
            traverse(child)
        }
    }
}
