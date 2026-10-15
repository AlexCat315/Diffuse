import GuavaUICore
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public extension Node {
    /// Window-space origin of this node: its local frame composed down the
    /// chain, with every ancestor's scroll offset applied to its content (see
    /// `Node.placementStep(scrolling:)`) and every ancestor's `transform`
    /// applied about its own anchor.
    ///
    /// This is THE walk for converting a node into window coordinates — any
    /// hand-rolled version that forgets the `contentOffset` term reports
    /// scrolled controls at their unscrolled position (the "dead dropdown
    /// after scrolling" bug class). It is the one walk that also accounts for
    /// scale, so a scaled node answers here the way it is drawn.
    var absoluteOrigin: CGPoint {
        let placed = absoluteTransform.origin
        return CGPoint(x: CGFloat(placed.x), y: CGFloat(placed.y))
    }

    /// Window-space frame of this node (see `absoluteOrigin`).
    ///
    /// Sized by the accumulated scale, so a node drawn at 0.96 reports a frame
    /// a caller can hit-test and a platform can hand to accessibility. A
    /// uniform scale composed with translations keeps the result axis-aligned.
    var absoluteFrame: CGRect {
        let transform = absoluteTransform
        return CGRect(x: CGFloat(transform.e),
                      y: CGFloat(transform.f),
                      width: frame.width * CGFloat(abs(transform.a)),
                      height: frame.height * CGFloat(abs(transform.d)))
    }

    /// Convert a window-space point into this node's local coordinates.
    func convertFromWindow(_ point: CGPoint) -> CGPoint {
        let local = absoluteTransform.inverted.applied(to: Float(point.x), Float(point.y))
        return CGPoint(x: CGFloat(local.x), y: CGFloat(local.y))
    }

    /// Maps a point in this node's local coordinates into window space.
    ///
    /// Internal rather than public because no caller outside this module needs
    /// the raw transform: everything outside asks for `absoluteOrigin`,
    /// `absoluteFrame` or `convertFromWindow`, which are expressed in terms a
    /// caller can use without knowing a transform is involved. The renderers
    /// and the hit tester are the callers that do want it.
    internal var absoluteTransform: Affine2D {
        var transform = placementStep(scrolling: .zero)
        var ancestor = parent
        while let current = ancestor {
            transform = transform.followed(by: current.placementStep(scrolling: current.contentOffset))
            ancestor = current.parent
        }
        return transform
    }
}