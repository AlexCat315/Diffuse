/// Owns the root node and drives depth-first traversal.
///
/// Usage:
/// ```swift
/// let tree = NodeTree()
/// tree.root = Node()
/// tree.markDirty(someChild)
/// tree.flush()   // resets layout + render invalidation flags after a frame
/// ```
public final class NodeTree: @unchecked Sendable {

    /// The single root of the scene graph.
    public var root: Node?

    public init() {}

    public var hasRenderUpdates: Bool {
        root?.renderDirty ?? false
    }

    // MARK: - Dirty management

    /// Convenience wrapper around `Node.markDirty()`.
    public func markDirty(_ node: Node) {
        node.markDirty()
    }

    public func markRenderDirty(_ node: Node) {
        node.markRenderDirty()
    }

    // MARK: - Flush

    /// Depth-first traversal that resets layout and render invalidation flags
    /// on every reachable node.
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
        node.renderDirty = false
        for child in node.children {
            traverse(child)
        }
    }
}
