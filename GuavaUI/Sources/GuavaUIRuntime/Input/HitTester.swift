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

    // MARK: - Phase 5b: InputScene-driven hit-test

    /// Hit-test the InputScene mirror against `point`. Reads the cached
    /// `isHitTestable` / `clipsToBounds` flags off `InputNode` rather than
    /// the live `Node`, so a future spatial index or per-node geometry
    /// snapshot only has to be hung off the input mirror. Frame is still
    /// read off the bound `Node` because layout writes back there.
    ///
    /// Phase 5c: short-circuits through `InputScene.cachedHitTest` when the
    /// mirror's structural version and the query point are unchanged from
    /// the previous call, so back-to-back dispatches on a stationary cursor
    /// (e.g. wheel after motion) skip the recursive walk.
    public static func hitTest(scene: InputScene, point: CGPoint) -> HitResult? {
        let cache = scene.cachedHitTest(at: point)
        if cache.cached {
            return cache.result
        }
        guard let root = scene.root else {
            scene.storeHitTest(at: point, result: nil)
            return nil
        }
        var path: [Node] = []
        let result = walk(input: root, pointInParent: point, path: &path)
        scene.storeHitTest(at: point, result: result)
        return result
    }

    private static func walk(input: InputNode,
                             pointInParent: CGPoint,
                             path: inout [Node]) -> HitResult? {
        guard let node = input.node else { return nil }
        let local = CGPoint(x: pointInParent.x - node.frame.origin.x,
                            y: pointInParent.y - node.frame.origin.y)
        let localBounds = CGRect(origin: .zero, size: node.frame.size)

        if input.clipsToBounds && !localBounds.contains(local) {
            return nil
        }

        path.append(node)

        // Children top-down (last drawn = top of z-order).
        for child in input.children.reversed() {
            if let hit = walk(input: child, pointInParent: local, path: &path) {
                return hit
            }
        }

        if input.isHitTestable && localBounds.contains(local) {
            return HitResult(node: node, path: path, localPoint: local)
        }

        path.removeLast()
        return nil
    }
}
