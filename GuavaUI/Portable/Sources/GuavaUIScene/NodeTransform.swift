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
///
/// The scale is a `Float` because that is what an animated value is on this
/// path; it becomes `CGFloat` at the geometry boundary in `NodeGeometry`.
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
/// `CGFloat` throughout: everything it maps is a `CGPoint` or `CGRect`, and
/// Swift has no implicit numeric conversion, so any other choice would mean
/// converting at every boundary instead of at the one place a transform enters.
struct Affine2D: Equatable, Sendable {
    var a: CGFloat
    var b: CGFloat
    var c: CGFloat
    var d: CGFloat
    var e: CGFloat
    var f: CGFloat

    init(a: CGFloat = 1, b: CGFloat = 0, c: CGFloat = 0,
         d: CGFloat = 1, e: CGFloat = 0, f: CGFloat = 0) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.e = e
        self.f = f
    }

    static let identity = Affine2D()

    /// Scale about `anchor`, given in the same space as the points being
    /// mapped. The anchor is the one point left untouched, so the offset it
    /// needs is `anchor * (1 - scale)` — and zero when the scale is one.
    init(scale: CGFloat, anchor: CGPoint) {
        a = scale
        b = 0
        c = 0
        d = scale
        e = anchor.x * (1 - scale)
        f = anchor.y * (1 - scale)
    }

    /// This transform applied to a point first, `next` second.
    func followed(by next: Affine2D) -> Affine2D {
        Affine2D(a: next.a * a + next.c * b,
                 b: next.b * a + next.d * b,
                 c: next.a * c + next.c * d,
                 d: next.b * c + next.d * d,
                 e: next.a * e + next.c * f + next.e,
                 f: next.b * e + next.d * f + next.f)
    }

    func applied(to point: CGPoint) -> CGPoint {
        CGPoint(x: a * point.x + c * point.y + e,
                y: b * point.x + d * point.y + f)
    }

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