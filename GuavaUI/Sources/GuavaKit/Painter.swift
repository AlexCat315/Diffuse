// Walks the node tree and emits a `DisplayList`. The traversal is the exact
// mirror of `HitTest`: children are visited in **ascending** z-order (so higher
// z paints last = on top), which is the reverse of hit-testing's descending
// order. Painting and hitting therefore always agree on what is "on top".

public struct Painter {
    public init() {}

    public func paint(root: UINode) -> DisplayList {
        var list = DisplayList()
        paint(node: root, parentContentOrigin: .zero, into: &list)
        return list
    }

    private func paint(node: UINode, parentContentOrigin: Point, into list: inout DisplayList) {
        let g = node.geometry
        let absFrame = Rect(x: parentContentOrigin.x + g.frame.minX,
                            y: parentContentOrigin.y + g.frame.minY,
                            width: g.frame.size.width,
                            height: g.frame.size.height)

        // Self paint (background under border).
        if let bg = node.paint.background { list.fill(absFrame, bg) }
        if let border = node.paint.border { list.stroke(absFrame, border.color, width: border.width) }

        if g.clipsToBounds { list.pushClip(absFrame) }

        // Children render translated by -contentOffset, in ascending z-order.
        let childOrigin = Point(x: absFrame.minX - g.contentOffset.x,
                                y: absFrame.minY - g.contentOffset.y)
        for child in paintOrderedChildren(node) {
            paint(node: child, parentContentOrigin: childOrigin, into: &list)
        }

        if g.clipsToBounds { list.popClip() }
    }

    /// Ascending z, and within equal z the earlier sibling first — i.e. exactly
    /// the reverse of `HitTest.orderedChildren`.
    private func paintOrderedChildren(_ node: UINode) -> [UINode] {
        node.children.enumerated()
            .sorted { a, b in
                if a.element.geometry.zIndex != b.element.geometry.zIndex {
                    return a.element.geometry.zIndex < b.element.geometry.zIndex
                }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}
