import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public extension Node {
    /// Window-space origin of this node: parent-local frames composed down the
    /// chain with every ancestor's scroll offset applied (children render
    /// translated by the parent's `-contentOffset`).
    ///
    /// This is THE walk for converting a node into window coordinates — any
    /// hand-rolled version that forgets the `contentOffset` term reports
    /// scrolled controls at their unscrolled position (the "dead dropdown
    /// after scrolling" bug class).
    var absoluteOrigin: CGPoint {
        var origin = frame.origin
        var current = parent
        while let parent = current {
            origin.x += parent.frame.origin.x - parent.contentOffset.x
            origin.y += parent.frame.origin.y - parent.contentOffset.y
            current = parent.parent
        }
        return origin
    }

    /// Window-space frame of this node (see `absoluteOrigin`).
    var absoluteFrame: CGRect {
        CGRect(origin: absoluteOrigin, size: frame.size)
    }

    /// Convert a window-space point into this node's local coordinates.
    func convertFromWindow(_ point: CGPoint) -> CGPoint {
        let origin = absoluteOrigin
        return CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }
}
