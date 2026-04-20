import GuavaUIRuntime

/// Type-erased helper that lets `ViewGraph` materialise (and update) a
/// `ModifiedContent` without knowing its generic parameters at the call site.
public protocol _AnyModifiedContent {
    func _materialiseInto(parent: Node,
                          layoutParent: LayoutNode?,
                          graph: ViewGraph) -> [Node]

    /// Re-apply this modifier to an already-existing node produced for this
    /// `ModifiedContent` slot. Reuses the node, recurses into the wrapped
    /// content, then re-applies the modifier (modifier writes are
    /// idempotent setters).
    func _updateInPlace(node: Node,
                        layoutParent: LayoutNode?,
                        graph: ViewGraph)
}

extension ModifiedContent: _AnyModifiedContent {

    public func _materialiseInto(parent: Node,
                                 layoutParent: LayoutNode?,
                                 graph: ViewGraph) -> [Node] {
        let nodes = graph.materialise(content, into: parent, layoutParent: layoutParent)
        for n in nodes {
            // Override the inner content's tag with the wrapper's tag so the
            // reconciler knows this slot carries a particular modifier
            // combination.
            n.viewTag = ViewGraph.slotTag(self)
            modifier.apply(node: n)
            if let ln = graph.layoutNode(for: n) {
                modifier.apply(layout: ln)
            }
        }
        return nodes
    }

    public func _updateInPlace(node: Node,
                               layoutParent: LayoutNode?,
                               graph: ViewGraph) {
        // Recurse into the wrapped content first so its primitive's
        // `_updateNode` runs and any deeper reconciliation happens.
        graph.updateInPlace(node: node, view: content, layoutParent: layoutParent)
        // Restore the wrapper tag (updateInPlace on the inner primitive may
        // have left the inner tag in place if it called something that wrote
        // viewTag; safe to overwrite unconditionally).
        node.viewTag = ViewGraph.slotTag(self)
        modifier.apply(node: node)
        if let ln = graph.layoutNode(for: node) {
            modifier.apply(layout: ln)
        }
    }
}
