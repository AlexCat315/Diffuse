import GuavaUICore
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// How a node scales its own subtree, and about which point.
///
/// The anchor is normalized within the node's frame: `(0, 0)` is the top-left
/// corner, `(0.5, 0.5)` the centre, `(1, 1)` the bottom-right. Normalized so
/// one value means the same thing at any size — a menu anchored at the corner
/// its trigger came from, and a button anchored at its centre, each say so
/// once rather than once per size.
///
/// Scale is uniform. A per-axis scale would fit the same shape here, but no
/// caller needs it yet, and one number is what an animation can hand straight
/// to a spring without inventing a second thing to interpolate.
public struct NodeTransform: Equatable, Sendable {
    /// Multiplier applied to both axes about the anchor. `1` leaves the subtree
    /// where layout put it; `0` collapses it onto the anchor point.
    public var scale: Float

    /// Point the scale is taken about, normalized within the node's frame.
    public var anchor: CGPoint

    public static let identity = NodeTransform()

    public init(scale: Float = 1, anchor: CGPoint = .zero) {
        self.scale = scale
        self.anchor = anchor
    }

    /// Whether this transform leaves the subtree exactly where it already is.
    public var isIdentity: Bool { scale == 1 }
}

/// Maps points from one space to another as a uniform scale plus a
/// translation.
///
/// Translation alone — which is all the tree needed before nodes could scale —
/// composes by summing origins. That is wrong the moment a scale is in the
/// chain, because where a point lands then depends on its position relative to
/// each ancestor's anchor, not just on how far the origins sum. So the ancestor
/// walk accumulates matrices instead.
///
/// Stored generally rather than special-cased for scale, so extending it to
/// rotation or a per-axis scale is arithmetic here instead of a second geometry
/// path on every consumer. Column-major, matching `CGAffineTransform`:
///
/// ```
/// | a  c  e |
/// | b  d  f |
/// ```
///
/// `Float`, not `CGFloat`, because the renderers thread this down the tree once
/// per node per frame and `DrawList` is already `Float` throughout. The
/// `CGPoint`/`CGRect` boundary converts in `NodeGeometry`, on a cold path,
/// rather than at every node.
struct Affine2D: Equatable, Sendable {
    var a: Float
    var b: Float
    var c: Float
    var d: Float
    var e: Float
    var f: Float

    init(a: Float = 1, b: Float = 0, c: Float = 0,
         d: Float = 1, e: Float = 0, f: Float = 0) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.e = e
        self.f = f
    }

    static let identity = Affine2D()

    /// This transform applied to a point first, `next` second.
    func followed(by next: Affine2D) -> Affine2D {
        Affine2D(a: next.a * a + next.c * b,
                 b: next.b * a + next.d * b,
                 c: next.a * c + next.c * d,
                 d: next.b * c + next.d * d,
                 e: next.a * e + next.c * f + next.e,
                 f: next.b * e + next.d * f + next.f)
    }

    func applied(to x: Float, _ y: Float) -> (x: Float, y: Float) {
        (a * x + c * y + e, b * x + d * y + f)
    }

    /// Where this transform puts the local origin — the only point the renderers
    /// need while descending, and cheaper than a full point mapping.
    var origin: (x: Float, y: Float) { (e, f) }

    /// The inverse, or the identity when the transform collapses a dimension.
    ///
    /// A zero scale has no inverse, and reporting the identity keeps a node
    /// collapsed by a transition from producing infinities in whatever asked to
    /// map a pointer back into it.
    var inverted: Affine2D {
        let determinant = a * d - b * c
        guard abs(determinant) > 1e-9 else { return .identity }
        let inverse = 1 / determinant
        return Affine2D(a:  d * inverse,
                        b: -b * inverse,
                        c: -c * inverse,
                        d:  a * inverse,
                        e: (c * f - d * e) * inverse,
                        f: (b * e - a * f) * inverse)
    }
}

extension Node {
    /// Maps a point in this node's local coordinates into its parent's, with
    /// `scrolling` applied to everything *inside* the node first.
    ///
    /// Pass `.zero` for where the node's own frame lands, and this node's
    /// `contentOffset` for where its content lands. That split is the whole
    /// subtlety: `contentOffset` slides a node's children and leaves the node
    /// where it is, so a node reporting its own origin scrolled would put
    /// reveal-into-view, hit testing and the platform drag regions off by
    /// exactly the scroll offset.
    ///
    /// The order is
    /// `frame.origin + (point - scrolling) * scale + anchor * size * (1 - scale)`,
    /// and the order is the point. Scroll is measured in the content's own
    /// units, so it comes out *before* the scale: scrolling 120pt inside a
    /// container drawn at 2× moves content 240pt across the screen, which is
    /// what a scroll view growing under your finger has to do. Scaling first
    /// would move it 120pt and read as the list sliding at half speed.
    ///
    /// The `anchor * size * (1 - scale)` term is what pins the anchor: the
    /// rectangle shrinks toward it, so shifting back by what came off each side
    /// leaves the anchor exactly where it was. At `scale == 1` both extra terms
    /// vanish and this is the bare translation it was before transforms existed.
    func placementStep(scrolling: CGPoint) -> Affine2D {
        let scale = transform.scale
        var result = Affine2D()
        result.a = scale
        result.b = 0
        result.c = 0
        result.d = scale
        result.e = Float(frame.origin.x) - Float(scrolling.x) * scale
            + Float(transform.anchor.x * frame.width) * (1 - scale)
        result.f = Float(frame.origin.y) - Float(scrolling.y) * scale
            + Float(transform.anchor.y * frame.height) * (1 - scale)
        return result
    }
}