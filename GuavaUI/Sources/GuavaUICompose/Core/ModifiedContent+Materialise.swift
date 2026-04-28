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
        // Scope-applying modifiers (e.g. CompositionLocal providers) must
        // expose their value to the content during materialisation, not after,
        // so descendants picking up `.foregroundColor(.semantic(...))` resolve
        // against the provided theme on first install — not against the
        // default. Wrap the content in a synthetic, layout-transparent anchor
        // and push the value onto it before recursing.
        if let scopeApply = modifier as? _ScopeApplyingModifier {
            let scopeAnchor = Node()
            scopeAnchor.isHitTestable = false
            scopeAnchor.viewTag = ViewGraph.slotTag(self)
            parent.addChild(scopeAnchor)
            scopeApply._applyScope(node: scopeAnchor)
            _ = graph.materialise(content,
                                  into: scopeAnchor,
                                  layoutParent: layoutParent)
            return [scopeAnchor]
        }

        if let around = modifier as? _AroundApplyingModifier {
            let anchor = Node()
            anchor.isHitTestable = false
            anchor.viewTag = ViewGraph.slotTag(self)
            parent.addChild(anchor)
            around._aroundApply(node: anchor) {
                _ = graph.materialise(content,
                                      into: anchor,
                                      layoutParent: layoutParent)
            }
            return [anchor]
        }

        let nodes = graph.materialise(content, into: parent, layoutParent: layoutParent)
        for n in nodes {
            // Override the inner content's tag with the wrapper's tag so the
            // reconciler knows this slot carries a particular modifier
            // combination.
            n.viewTag = ViewGraph.slotTag(self)
            for target in modifierTargets(for: n, graph: graph) {
                modifier.apply(node: target)
                if let ln = graph.layoutNode(for: target) {
                    modifier.apply(layout: ln)
                }
            }
        }
        return nodes
    }

    public func _updateInPlace(node: Node,
                               layoutParent: LayoutNode?,
                               graph: ViewGraph) {
        // Mirror the materialise-time wrapping: scope-applying modifiers own a
        // synthetic anchor whose single child carries the wrapped content.
        if let scopeApply = modifier as? _ScopeApplyingModifier {
            node.viewTag = ViewGraph.slotTag(self)
            if scopeApply._applyScope(node: node) {
                graph.reconcileChildren(parent: node,
                                        layoutParent: layoutParent,
                                        newViews: [content])
            }
            return
        }

        if let around = modifier as? _AroundApplyingModifier {
            node.viewTag = ViewGraph.slotTag(self)
            around._aroundApply(node: node) {
                graph.reconcileChildren(parent: node,
                                        layoutParent: layoutParent,
                                        newViews: [content])
            }
            return
        }

        // Recurse into the wrapped content first so its primitive's
        // `_updateNode` runs and any deeper reconciliation happens.
        graph.updateInPlace(node: node, view: content, layoutParent: layoutParent)
        // Restore the wrapper tag (updateInPlace on the inner primitive may
        // have left the inner tag in place if it called something that wrote
        // viewTag; safe to overwrite unconditionally).
        node.viewTag = ViewGraph.slotTag(self)
        for target in modifierTargets(for: node, graph: graph) {
            modifier.apply(node: target)
            if let ln = graph.layoutNode(for: target) {
                modifier.apply(layout: ln)
            }
        }
    }

    private func modifierTargets(for node: Node,
                                 graph: ViewGraph) -> [Node] {
        if graph.layoutNode(for: node) != nil || node.children.isEmpty {
            return [node]
        }

        return node.children.flatMap { modifierTargets(for: $0, graph: graph) }
    }
}
