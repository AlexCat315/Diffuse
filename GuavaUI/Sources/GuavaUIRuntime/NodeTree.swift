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
    /// Layout (`LayoutTree`/Yoga) and draw (`LayerAwareNodeRenderer`) are
    /// driven directly by `ViewGraph` and `EngineHost.tick`; this method
    /// only clears the per-`Node` dirty flags after each frame so the next
    /// recompose can detect new mutations.
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
