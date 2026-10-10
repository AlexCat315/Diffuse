import GuavaUICore

/// Maps a raw overscroll past a scroll bound onto the smaller, progressively
/// stiffening distance that is actually drawn — the rubber band.
///
/// The curve is UIKit's:
///
/// ```
/// projected(x) = (c · |x| · d) / (d + c · |x|)
/// ```
///
/// where `x` is signed overscroll, `d` the viewport extent along the scrolled
/// axis and `c` the compliance (initial slope). Three properties fall out of
/// this shape and are the reason it is used instead of, say, halving the
/// distance:
/// - slope at `x = 0` is exactly `c`, so the first point after the bound feels
///   like the configured resistance rather than like a dead zone;
/// - the function is monotonically increasing, so dragging further always
///   moves further — never "sticks";
/// - it approaches `d` asymptotically, so content can never be dragged further
///   off-screen than one viewport, no matter how hard the user pushes.
public enum RubberBand {
    /// Project `overscroll` (signed, may be negative for the leading bound)
    /// onto the visible displacement.
    ///
    /// - Parameters:
    ///   - overscroll: distance past the bound, in content points.
    ///   - extent: viewport size along the same axis. Must be positive for the
    ///     elastic response to exist; with no viewport there is nothing to
    ///     stretch against, so the result is `0` (hard clamp).
    ///   - compliance: initial slope, see `ScrollRubberBandSettings`.
    /// - Returns: the displacement actually applied to the content.
    public static func project(overscroll: Float,
                               extent: Float,
                               compliance: Float) -> Float {
        guard overscroll != 0, extent > 0, compliance > 0 else { return 0 }
        let distance = abs(overscroll)
        let resilience = compliance * distance * extent
        let projected = resilience / (extent + compliance * distance)
        return overscroll < 0 ? -projected : projected
    }

    /// Signed overscroll of `value` against the closed range `0...maximum`.
    /// `0` when inside the range.
    public static func excess(of value: Float, maximum: Float) -> Float {
        if value < 0 { return value }
        if value > maximum { return value - maximum }
        return 0
    }

    /// Inverse of `project` — recovers how far input must have pushed to reach
    /// the given visible displacement.
    ///
    /// Needed when new input interrupts an in-flight return spring: whatever
    /// the spring has already recovered has to be folded back into the raw
    /// position through this inverse, otherwise the content jumps back out to
    /// the full stretch on every new delta.
    ///
    /// Returns `0` when the displacement is not achievable (`visibleOverscroll`
    /// at or past the `extent` asymptote) rather than diverging.
    public static func unproject(visibleOverscroll: Float,
                                 extent: Float,
                                 compliance: Float) -> Float {
        guard visibleOverscroll != 0, extent > 0, compliance > 0 else { return 0 }
        let remaining = extent - abs(visibleOverscroll)
        guard remaining > 0 else { return 0 }
        let raw = (visibleOverscroll * extent) / (compliance * remaining)
        return raw
    }
}
