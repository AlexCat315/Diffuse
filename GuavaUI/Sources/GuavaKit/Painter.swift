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
        let p = node.paint
        let absFrame = Rect(x: parentContentOrigin.x + g.frame.minX,
                            y: parentContentOrigin.y + g.frame.minY,
                            width: g.frame.size.width,
                            height: g.frame.size.height)

        // Self paint (background under border, then text on top).
        // Opacity multiplies the colour alpha channel.
        if let bg = p.background {
            let c = p.opacity < 1 ? Color(r: bg.r, g: bg.g, b: bg.b, a: bg.a * p.opacity) : bg
            if let r = p.cornerRadius, r > 0 {
                list.fillRounded(absFrame, c, radius: r)
            } else {
                list.fill(absFrame, c)
            }
        }
        if let border = p.border {
            let bc = p.opacity < 1
                ? Color(r: border.color.r, g: border.color.g, b: border.color.b,
                        a: border.color.a * p.opacity)
                : border.color
            list.stroke(absFrame, bc, width: border.width)
        }
        if let t = node.textContent {
            let tc = p.opacity < 1
                ? Color(r: t.color.r, g: t.color.g, b: t.color.b, a: t.color.a * p.opacity)
                : t.color
            list.text(t.string, absFrame, tc, size: t.size, lineLimit: node.textLineLimit)
        }

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
