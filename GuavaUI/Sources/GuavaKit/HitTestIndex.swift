/// Hit-test cache + walker.
///
/// The legacy bug was here: the cache was keyed on a *structural* version that
/// a geometry-only move didn't bump, so a moved control kept returning a stale
/// hit and "stopped responding". GuavaKit removes the failure mode entirely:
/// the cache is invalidated by `UIContext.invalidate` whenever `.geometry` or
/// `.hierarchy` changes, and geometry can *only* change through that path.
public final class HitTestIndex {
    private var cachedPoint: Point?
    private var cachedResult: HitTest.Result?

    public private(set) var hits = 0
    public private(set) var misses = 0

    /// Dropped on any geometry/hierarchy change (called by `UIContext`).
    public func invalidate() {
        cachedPoint = nil
        cachedResult = nil
    }

    /// Hit-test `point` (root coordinate space) against the subtree at `root`.
    /// Serves a cached answer only for the exact same point since the last
    /// invalidation; any tree change since then has already cleared it.
    public func hitTest(_ point: Point, in root: UINode?) -> HitTest.Result? {
        if let cachedPoint, cachedPoint == point {
            hits += 1
            return cachedResult
        }
        misses += 1
        let result = root.flatMap { HitTest.walk(node: $0, pointInParent: point, path: []) }
        cachedPoint = point
        cachedResult = result
        return result
    }
}

public enum HitTest {
    public struct Result {
        /// The deepest hit-testable node under the point.
        public let node: UINode
        /// Root → node path (inclusive), for capture/bubble traversal.
        public let path: [UINode]
        /// Point in `node`'s local coordinate space.
        public let localPoint: Point
    }

    /// Depth-first, top-of-z-order first. Mirrors paint order: a node's children
    /// render after it, last/highest-z on top, so hit-testing visits them in
    /// reverse z-then-order and returns the first claim.
    static func walk(node: UINode, pointInParent: Point, path: [UINode]) -> Result? {
        let g = node.geometry
        let local = Point(x: pointInParent.x - g.frame.minX,
                          y: pointInParent.y - g.frame.minY)

        // Clipping rejects the whole subtree when the point is outside the frame.
        if g.clipsToBounds && !g.frame.size.contains(local: local) {
            return nil
        }

        let path = path + [node]
        // Children are translated by -contentOffset, so descend with the inverse.
        let childPoint = Point(x: local.x + g.contentOffset.x,
                               y: local.y + g.contentOffset.y)
        for child in orderedChildren(node) {
            if let hit = walk(node: child, pointInParent: childPoint, path: path) {
                return hit
            }
        }

        if g.isHitTestable && g.frame.size.contains(local: local) {
            return Result(node: node, path: path, localPoint: local)
        }
        return nil
    }

    /// Children sorted for hit-testing: higher z first, and within equal z, the
    /// later sibling (painted on top) first.
    private static func orderedChildren(_ node: UINode) -> [UINode] {
        node.children.enumerated()
            .sorted { a, b in
                if a.element.geometry.zIndex != b.element.geometry.zIndex {
                    return a.element.geometry.zIndex > b.element.geometry.zIndex
                }
                return a.offset > b.offset
            }
            .map(\.element)
    }
}

private extension Size {
    func contains(local p: Point) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x <= width && p.y <= height
    }
}
