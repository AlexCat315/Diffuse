import GuavaUICore
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Result of a hit test — the deepest hit-testable node containing the point,
/// plus the chain from root → node for capture/bubble traversal.
public struct HitResult {
    /// Deepest hit-testable node under the point.
    public let node: Node
    /// Path from root to `node`, inclusive at both ends.
    public let path: [Node]
    /// Point in `node`'s local coordinate space.
    public let localPoint: CGPoint
}
/// Hit-tests a `Node` tree against a window-local point.
///
/// Algorithm:
/// - Frames are parent-local (set by `LayoutPass` from Yoga output).
/// - Points are mapped into a node's space by the *inverse* of the same
///   placement the renderers use, so a scaled node is hit where it is drawn
///   rather than where layout left it.
/// - Children are drawn in array order (last child on top → reverse iterate).
/// - `clipsToBounds == true` rejects child hits outside this node's frame.
/// - `isHitTestable == false` skips a node but keeps walking its children
///   (matches CSS `pointer-events: none` semantics for the node alone).
public struct HitTester {

    public static func hitTest(rootNode root: Node, point: CGPoint) -> HitResult? {
        var path: [Node] = []
        guard let result = walk(node: root, pointInParent: point, path: &path) else {
            return nil
        }
        return result
    }

    private static func walk(node: Node,
                             pointInParent: CGPoint,
                             path: inout [Node]) -> HitResult? {
        guard node.isLayoutVisible, node.allowsHitTesting, node.isInteractionEnabled else { return nil }
        // A node collapsed to nothing by a transition has no area to hit.
        // Checked before the inverse, because a zero scale has no inverse and
        // the fallback would report the node at full size — the one answer
        // that is certainly wrong.
        guard node.transform.scale != 0 else { return nil }

        // Convert into this node's local coordinate space, undoing the scale as
        // well as the origin. The bounds below stay the layout rect: local
        // space is pre-scale, so the same unscaled rectangle still answers
        // "is the point inside this node", and `HitResult.localPoint` keeps
        // meaning what it always did for callers measuring within the node.
        let own = node.placementStep(scrolling: .zero)
        let localMapped = own.source(of: (Float(pointInParent.x), Float(pointInParent.y)))
        let local = CGPoint(x: CGFloat(localMapped.x), y: CGFloat(localMapped.y))
        let localBounds = CGRect(origin: .zero, size: node.frame.size)

        // If this node clips and the point is outside its frame, the entire
        // subtree is rejected immediately.
        if node.clipsToBounds && !localBounds.contains(local) {
            return nil
        }

        path.append(node)
        defer { if path.last === node { /* keep on success */ } }

        // Traverse children top-down (last child = top of z-order). Children
        // render at the node's *content* placement — its frame slid by
        // `-contentOffset` and then scaled — so descend through the inverse of
        // that, not the node's own.
        let content = node.placementStep(scrolling: node.contentOffset)
        let childMapped = content.source(of: (Float(pointInParent.x), Float(pointInParent.y)))
        let childPoint = CGPoint(x: CGFloat(childMapped.x), y: CGFloat(childMapped.y))
        if node.childrenMayNeedZSort {
            for child in hitTestOrderedChildren(of: node) {
                if let hit = walk(node: child, pointInParent: childPoint, path: &path) {
                    return hit
                }
            }
        } else {
            for child in node.children.reversed() {
                if let hit = walk(node: child, pointInParent: childPoint, path: &path) {
                    return hit
                }
            }
        }

        // No child claimed the point; can this node claim it?
        if node.isHitTestable && localBounds.contains(local) {
            return HitResult(node: node, path: path, localPoint: local)
        }

        // Backtrack the path entry we appended.
        path.removeLast()
        return nil
    }

    private static func hitTestOrderedChildren(of node: Node) -> [Node] {
        node.children.enumerated()
            .sorted { lhs, rhs in
                let lhsZ = lhs.element.zIndex
                let rhsZ = rhs.element.zIndex
                if lhsZ == rhsZ { return lhs.offset > rhs.offset }
                return lhsZ > rhsZ
            }
            .map { $0.element }
    }
}
