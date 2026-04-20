import GuavaUIRuntime

/// Type-erased helper that lets `ViewGraph` materialise a `ModifiedContent`
/// without knowing its generic parameters at the call site.
public protocol _AnyModifiedContent {
    func _materialiseInto(parent: Node,
                          layoutParent: LayoutNode?,
                          graph: ViewGraph) -> [Node]
}

extension ModifiedContent: _AnyModifiedContent {
    public func _materialiseInto(parent: Node,
                                 layoutParent: LayoutNode?,
                                 graph: ViewGraph) -> [Node] {
        let nodes = graph.materialise(content, into: parent, layoutParent: layoutParent)
        for n in nodes {
            modifier.apply(node: n)
            if let ln = graph.layoutNode(for: n) {
                modifier.apply(layout: ln)
            }
        }
        return nodes
    }
}
