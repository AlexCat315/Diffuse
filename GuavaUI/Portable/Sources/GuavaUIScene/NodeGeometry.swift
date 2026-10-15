import GuavaUICore
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public extension Node {
    /// Window-space origin of this node: its local frame composed down the
    /// chain, with every ancestor's scroll offset applied (children render
    /// translated by the parent's `-contentOffset`) and every ancestor's
    /// `transform` applied about its own anchor.
    ///
    /// This is THE walk for converting a node into window coordinates — any
    /// hand-rolled version that forgets the `contentOffset` term reports
    /// scrolled controls at their unscrolled position (the "dead dropdown
    /// after scrolling" bug class). It is the one walk that also accounts for
    /// scale, so a scaled node answers the same way here as it is drawn.
    var absoluteOrigin: CGPoint {
        let transform = absoluteTransform
        return CGPoint(x: transform.e, y: transform.f)
    }

    /// Window-space frame of this node (see `absoluteOrigin`).
    ///
    /// Sized by the accumulated scale, so a node drawn at 0.96 reports a frame
    /// a caller can hit-test and a platform can hand to accessibility. A
    /// uniform scale composed with translations keeps the result axis-aligned.
    var absoluteFrame: CGRect {
        let transform = absoluteTransform
        return CGRect(x: transform.e,
                      y: transform.f,
                      width: frame.width * abs(transform.a),
                      height: frame.height * abs(transform.d))
    }

    /// Convert a window-space point into this node's local coordinates.
    func convertFromWindow(_ point: CGPoint) -> CGPoint {
        absoluteTransform.inverted.applied(to: point)
    }

    /// Maps a point in this node's local coordinates into window space.
    ///
    /// Internal rather than public because no caller outside this module needs
    /// the raw transform: everything outside asks for `absoluteOrigin`,
    /// `absoluteFrame` or `convertFromWindow`, which are expressed in terms a
    /// caller can use without knowing a transform is involved. The renderers
    /// and the hit tester are the callers that do want it.
    internal var absoluteTransform: Affine2D {
        var transform = step(scrolling: .zero)
        var ancestor = parent
        while let current = ancestor {
            transform = transform.followed(by: current.step(scrolling: current.contentOffset))
            ancestor = current.parent
        }
        return transform
    }

    /// Maps a point in this node's local coordinates into its parent's.
    ///
    /// `scrolling` is the scroll applied to everything *inside* the node.
    /// `.zero` for the node itself, because `contentOffset` slides a node's
    /// children and leaves the node where it is — a scroll view scrolls its
    /// content underneath itself. An ancestor passes its own offset down, which
    /// is the only place that term belongs: a node reporting its own origin
    /// scrolled would put reveal-into-view, hit testing and the platform drag
    /// regions off by exactly the scroll offset.
    ///
    /// The order is `frame.origin + (point - scrolling) * scale + anchor * (1 - scale)`,
    /// and the order is the point. Scroll is measured in the content's own
    /// units, so it is taken out *before* the scale: scrolling 120pt inside a
    /// container drawn at 2× moves the content 240pt across the screen, which
    /// is what a scroll view that grows under your finger has to do. Scaling
    /// first would move it 120pt and read as the list sliding at half speed.
    ///
    /// The `anchor * (1 - scale)` term is what pins the anchor: the rectangle
    /// shrinks toward it by the scale, so shifting back by what came off each
    /// side leaves the anchor exactly where it was. At `scale == 1` both terms
    /// vanish and this is the bare translation it was before transforms existed.
    private func step(scrolling: CGPoint) -> Affine2D {
        let scale = CGFloat(transform.scale)
        var result = Affine2D()
        result.a = scale
        result.b = 0
        result.c = 0
        result.d = scale
        result.e = frame.origin.x - scrolling.x * scale
            + transform.anchor.x * frame.width * (1 - scale)
        result.f = frame.origin.y - scrolling.y * scale
            + transform.anchor.y * frame.height * (1 - scale)
        return result
    }
}