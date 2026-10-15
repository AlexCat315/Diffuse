import GuavaUIScene

/// Type-erased helper that lets `ViewGraph` materialise (and update) a
/// `ModifiedContent` without knowing its generic parameters at the call site.
public protocol _AnyModifiedContent {
    /// Ordinary modifiers share their content's node and therefore its key.
    /// Scope/around modifiers create a new anchor and keep the child's key local.
    var _inheritedSlotKey: AnyHashable? { get }

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

public extension _AnyModifiedContent {
    var _inheritedSlotKey: AnyHashable? { nil }
}

extension ModifiedContent: _AnyModifiedContent {

    public var _inheritedSlotKey: AnyHashable? {
        guard !(modifier is _ScopeApplyingModifier),
              !(modifier is _AroundApplyingModifier) else { return nil }
        return ViewGraph.slotKey(content)
    }

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
            _ = scopeApply._applyScope(node: scopeAnchor)
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

        if Self.hasStructuralContent(content) {
            // A conditional/tuple/array can produce several roots. It needs
            // its own slot: overwriting a child's viewTag would replace that
            // child's user scope with the structural value on the next update.
            let anchor = Node()
            anchor.isHitTestable = false
            anchor.viewTag = ViewGraph.slotTag(self)
            parent.addChild(anchor)
            _ = graph.materialise(content, into: anchor, layoutParent: layoutParent)
            applyModifier(to: anchor, graph: graph)
            return [anchor]
        }

        let nodes = graph.materialise(content, into: parent, layoutParent: layoutParent)
        for n in nodes {
            // Override the inner content's tag with the wrapper's tag so the
            // reconciler knows this slot carries a particular modifier
            // combination.
            n.viewTag = ViewGraph.slotTag(self)
            retainModifier(on: n, graph: graph)
            for target in Self.modifierTargets(for: n, graph: graph) {
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
            ModifierReplay.reset(on: node)
            // The content must reconcile even when the provided value is
            // unchanged: this slot was handed a NEW content value (fresh
            // closures and bindings into the owning scope's current @State
            // storage). Skipping the recursion strands descendants on
            // captures of storage that `ViewScope.replaceView` has already
            // swapped out — controls keep writing into dead state.
            let changed = scopeApply._applyScope(node: node)
            let previous = graph.environmentReasons
            if changed { graph.environmentReasons.append(.init(kind: "environment", detail: "CompositionLocal", originScope: graph.activeRecompositionScope)) }
            defer { graph.environmentReasons = previous }
            graph.reconcileChildren(parent: node,
                                    layoutParent: layoutParent,
                                    newViews: [content])
            return
        }

        if let around = modifier as? _AroundApplyingModifier {
            node.viewTag = ViewGraph.slotTag(self)
            ModifierReplay.reset(on: node)
            around._aroundApply(node: node) {
                graph.reconcileChildren(parent: node,
                                        layoutParent: layoutParent,
                                        newViews: [content])
            }
            return
        }

        if Self.hasStructuralContent(content) {
            ModifierReplay.reset(on: node)
            graph.reconcileChildren(parent: node, layoutParent: layoutParent, newViews: [content])
            node.viewTag = ViewGraph.slotTag(self)
            applyModifier(to: node, graph: graph)
            return
        }

        // Recurse into the wrapped content first so its primitive's
        // `_updateNode` runs and any deeper reconciliation happens.
        graph.updateInPlace(node: node, view: content, layoutParent: layoutParent)
        // Restore the wrapper tag (updateInPlace on the inner primitive may
        // have left the inner tag in place if it called something that wrote
        // viewTag; safe to overwrite unconditionally).
        node.viewTag = ViewGraph.slotTag(self)
        retainModifier(on: node, graph: graph)
        for target in Self.modifierTargets(for: node, graph: graph) {
            modifier.apply(node: target)
            if let ln = graph.layoutNode(for: target) {
                modifier.apply(layout: ln)
            }
        }
    }

    private static func hasStructuralContent(_ view: any View) -> Bool {
        // Check Optional's own conformance before casts that can implicitly
        // unwrap its non-nil, source-located payload.
        if view is any _StructuralView { return true }
        if let source = view as? _AnySourceLocatedView { return hasStructuralContent(source._sourceContent) }
        if let identified = view as? _AnyIdentifiedView { return hasStructuralContent(identified._content) }
        if let erased = view as? AnyView { return hasStructuralContent(erased.storage) }
        return false
    }

    private func applyModifier(to node: Node, graph: ViewGraph) {
        retainModifier(on: node, graph: graph)
        for target in Self.modifierTargets(for: node, graph: graph) {
            modifier.apply(node: target)
            if let layout = graph.layoutNode(for: target) { modifier.apply(layout: layout) }
        }
    }

    private func retainModifier(on node: Node, graph: ViewGraph) {
        guard graph.layoutNode(for: node) == nil, !node.children.isEmpty else { return }
        ModifierReplay.install(on: node) { [weak node, weak graph, modifier] in
            guard let node, let graph else { return }
            for target in Self.modifierTargets(for: node, graph: graph) {
                modifier.apply(node: target)
                if let layout = graph.layoutNode(for: target) { modifier.apply(layout: layout) }
            }
        }
    }

    private static func modifierTargets(for node: Node,
                                 graph: ViewGraph) -> [Node] {
        if graph.layoutNode(for: node) != nil || node.children.isEmpty {
            return [node]
        }

        return node.children.flatMap { Self.modifierTargets(for: $0, graph: graph) }
    }
}
