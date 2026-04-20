import GuavaUIRuntime

/// Type-erased helper that lets `ViewGraph` materialise a `ModifiedContent`
/// without knowing its generic parameters at the call site.
public protocol _AnyModifiedContent {
    func _materialiseInto(parent: Node, graph: ViewGraph) -> [Node]
}

extension ModifiedContent: _AnyModifiedContent {
    public func _materialiseInto(parent: Node, graph: ViewGraph) -> [Node] {
        let nodes = graph.materialise(content, into: parent)
        for n in nodes { modifier.apply(node: n) }
        return nodes
    }
}
