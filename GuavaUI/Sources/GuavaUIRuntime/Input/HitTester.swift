import Foundation
import CoreGraphics

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
        // Convert into this node's local coordinate space.
        let local = CGPoint(x: pointInParent.x - node.frame.origin.x,
                            y: pointInParent.y - node.frame.origin.y)
        let localBounds = CGRect(origin: .zero, size: node.frame.size)

        // If this node clips and the point is outside its frame, the entire
        // subtree is rejected immediately.
        if node.clipsToBounds && !localBounds.contains(local) {
            return nil
        }

        path.append(node)
        defer { if path.last === node { /* keep on success */ } }

        // Traverse children top-down (last child = top of z-order).
        for child in node.children.reversed() {
            if let hit = walk(node: child, pointInParent: local, path: &path) {
                return hit
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
}
